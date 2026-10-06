package com.procompanion.core_host_spike

import android.Manifest
import android.app.BroadcastOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * #15 criterion 3: an emitter not signed with the pinned certificate is refused, and
 * nothing it sends reaches the core. link_tests.sh runs this twice: with the harness
 * re-signed by the imposter key (`-e expect untrusted`), then by the pinned key
 * (`-e expect trusted`), which is the control that the same path accepts a trusted
 * emitter. Both copies of the harness carry the pinned package, so only the
 * certificate tells them apart.
 *
 * The harness is started through the shell, as link_run.sh starts it, and the core
 * is this spike's real host, started as IntentReachesHeadlessDartTest starts it.
 */
@RunWith(AndroidJUnit4::class)
class LinkTrustTest {
    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.POST_NOTIFICATIONS,
    )

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val coreLog = File(context.filesDir, "core_tick.log")
    private val rejectLog = File(context.filesDir, LinkInbox.REJECT_LOG)
    private val expect = InstrumentationRegistry.getArguments().getString("expect") ?: "trusted"

    @Before
    fun startCore() {
        val from = if (coreLog.exists()) coreLog.length() else 0L
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { it.startForegroundService(Intent(it, CoreService::class.java)) }
        waitFor("the headless core to start") { coreLog.exists() && tail(coreLog, from).contains(" START") }
        scenario.close() // the link must work with the activity gone
    }

    @After
    fun stopCore() {
        context.stopService(Intent(context, CoreService::class.java))
    }

    @Test
    fun broadcast() = exercise("broadcast", answer = "sent")

    @Test
    fun boundService() = exercise("bound", answer = LinkContract.REFUSED)

    @Test
    fun contentProvider() = exercise("provider", answer = LinkContract.REFUSED)

    /**
     * The package half of LinkTrust. The imposter carries the pinned package, so it
     * cannot show that a caller with any other package is refused, and LinkTrust's
     * certificate check reads the PINNED package's signer, not the caller's: without
     * the package check, any app could send while the trusted harness is installed.
     * This test is that other app, calling from the companion's own UID.
     */
    @Test
    fun anotherPackageIsRefused() {
        val run = "t-self-${System.nanoTime()}"
        val event = """{"v":1,"id":"self-$run","kind":"start","at_ms":${System.currentTimeMillis()},"x_run":"$run"}"""
        for (mech in listOf("broadcast", "bound", "provider")) {
            val before = refusals(mech, "package_not_pinned")
            val told = when (mech) {
                "broadcast" -> {
                    val options = BroadcastOptions.makeBasic().setShareIdentityEnabled(true)
                    context.sendBroadcast(
                        Intent(LinkContract.ACTION_EVENT).setPackage(context.packageName).putExtra(LinkContract.EXTRA_EVENT, event),
                        null,
                        options.toBundle(),
                    )
                    "sent"
                }
                "bound" -> bindAndSend(event)
                else -> context.contentResolver.call(Uri.parse("content://$AUTHORITY"), LinkContract.METHOD_EVENT, event, null)
                    ?.getString(LinkContract.KEY_STATUS)
            }
            waitFor("a package_not_pinned refusal over $mech") { refusals(mech, "package_not_pinned") > before }
            if (mech != "broadcast") assertEquals("what another package was told over $mech", LinkContract.REFUSED, told)
        }
        Thread.sleep(2_000)
        assertEquals("events from another package reached the core", 0, coreLines(run))
    }

    private fun bindAndSend(event: String): String? {
        val connected = CountDownLatch(1)
        var binder: IBinder? = null
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                binder = service
                connected.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName) {}
        }
        context.bindService(Intent(context, LinkService::class.java), connection, Context.BIND_AUTO_CREATE)
        try {
            connected.await(10, TimeUnit.SECONDS)
            val data = Parcel.obtain()
            val reply = Parcel.obtain()
            try {
                data.writeInterfaceToken(LinkContract.DESCRIPTOR)
                data.writeString(event)
                binder!!.transact(LinkContract.TX_EVENT, data, reply, 0)
                reply.readException()
                return reply.readString()
            } finally {
                data.recycle()
                reply.recycle()
            }
        } finally {
            context.unbindService(connection)
        }
    }

    /** [answer] is what an untrusted emitter is told; a broadcast tells it nothing. */
    private fun exercise(mech: String, answer: String) {
        val run = "t-$mech-${System.nanoTime()}"
        val refusedBefore = refusals(mech)
        shell("am start-foreground-service -n $HARNESS/.EmitService --es mech $mech --ei count $N --ei interval_ms 200 --es run $run")
        waitFor("the harness to finish $run") { harnessLines(run).any { "DONE run=$run " in it } }
        Thread.sleep(2_000) // anything still in flight reaches the core or does not
        val told = harnessLines(run).filter { "EMIT run=$run " in it }.map { it.substringAfter("status=").substringBefore(' ') }
        when (expect) {
            "untrusted" -> {
                assertEquals("events from an untrusted emitter reached the core", 0, coreLines(run))
                assertEquals("refusals for the certificate over $mech", N, refusals(mech) - refusedBefore)
                assertEquals("what the untrusted emitter was told", List(N) { answer }, told)
            }
            "trusted" -> {
                assertEquals("events from the trusted emitter in the core", N, coreLines(run))
                assertEquals("refusals over $mech", 0, refusals(mech) - refusedBefore)
                val accepted = if (mech == "broadcast") "sent" else LinkContract.ACCEPTED
                assertEquals("what the trusted emitter was told", List(N) { accepted }, told)
            }
            else -> throw IllegalArgumentException("expect must be trusted or untrusted, not $expect")
        }
    }

    private fun coreLines(run: String) = coreLog.readLines().count { " LINK run=$run " in it }

    /**
     * Refusals for [reason]. By default the certificate, the one thing the two harness
     * copies differ in: a refusal by any other check is not the one under test.
     */
    private fun refusals(mech: String, reason: String = "certificate_not_pinned") =
        if (rejectLog.exists()) rejectLog.readLines().count { "mech=$mech " in it && "reason=$reason " in it } else 0

    private fun harnessLines(run: String) = shell("logcat -d -s LINK:I").lines().filter { "run=$run " in it }

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
            .use { it.readBytes().decodeToString() }

    private fun tail(file: File, from: Long) = file.readText().substring(from.toInt().coerceAtMost(file.length().toInt()))

    private fun waitFor(what: String, timeoutMs: Long = 60_000, check: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (runCatching(check).getOrDefault(false)) return
            Thread.sleep(250)
        }
        throw AssertionError("timed out waiting for $what")
    }

    companion object {
        const val HARNESS = "com.procompanion.link_harness"
        const val AUTHORITY = "com.procompanion.core_host_spike.link"
        const val N = 3
    }
}
