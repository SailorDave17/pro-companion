package com.procompanion.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.Process
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * #33 on a device: race-timer's link against the real app, its real log and the real binder path.
 * integration_test/race_timer_link.sh runs this class twice with the same app build, the stand-in
 * (tool/core_host_spike/android/harness) signed by a key the build pins (`-e expect trusted`) and
 * then by one it does not (`-e expect imposter`). Both copies carry race-timer's package, so only
 * the certificate tells them apart. The stand-in is a separate APK because this test runs in the
 * app's own process and UID, and can only ever be the caller with another package.
 *
 * What the day below proves is processes and binder calls under Doze's rules, not a phone's timing:
 * instrumentation holds this process up, and an emulator's CPU never suspends (ADR 003, ADR 004).
 * integration_test/link_kill.sh is the path with no instrumentation under it.
 */
class RaceTimerLinkTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val probe = CoreHostProbe(instrumentation)
    private val expect = InstrumentationRegistry.getArguments().getString("expect")

    /** The stand-in's line for one emission, as EmitService logs it under the tag LINK. */
    private class Emit(line: String) {
        val id = field(line, "id")
        val kind = field(line, "kind")
        val atMs = field(line, "at_ms").toLong()
        val status = field(line, "status")
        val idle = field(line, "idle")
        val resend = " resend=true" in line

        private fun field(line: String, key: String): String =
            Regex("\\b$key=(\\S+)").find(line)?.groupValues?.get(1)
                ?: throw AssertionError("no $key on the stand-in's line: $line")
    }

    @Before
    fun wake() {
        assertTrue("expect must be trusted or imposter, not $expect", expect == "trusted" || expect == "imposter")
        device.wakeUp()
        device.executeShellCommand("wm dismiss-keyguard")
    }

    @After
    fun stopTheHost() {
        stopHost()
        device.pressHome()
    }

    /**
     * Criteria 1, 2, 6, 7 and 8's buzz end to end. One day of the stand-in's script, which carries every
     * contract kind, with the activity destroyed, the core in the foreground and the device in
     * forced Doze. Each EMIT line must say idle=true, or the run proved nothing about Doze. The same
     * path, conditions and calls in both phases, so the signer is the only thing that differs.
     */
    @Test
    fun criteria6And7_aDayInForcedDozeWithTheActivityDestroyedIsStoredOrRefusedByItsSigner() {
        hostUp()
        val run = "day-${System.nanoTime()}"
        val startedMs = System.currentTimeMillis()
        val buzzedBefore = buzzes()

        inForcedDoze {
            val emits = emit(run, count = DAY_EVENTS, intervalMs = 1_000, resend = RESENT_EVENT)

            assertEquals("the stand-in's lines, the resend included", DAY_EVENTS + 1, emits.size)
            assertEquals("the ids the run sent, a resend reusing one", DAY_EVENTS, emits.map { it.id }.toSet().size)
            assertEquals("the resend must be one line, under the id of event $RESENT_EVENT", 1, emits.count { it.resend })
            assertEquals(
                "every event must be sent in Doze, or this run proves nothing about it",
                List(emits.size) { "true" },
                emits.map { it.idle },
            )
            assertTrue("the core host left the foreground during the run", probe.coreHostForeground())
            if (expect == "trusted") {
                everyEventStoredOnce(emits, startedMs)
                oneBuzzPerStoredEvent(buzzedBefore)
            } else {
                nothingStoredAndEveryEventRefused(emits, startedMs)
                assertEquals("an imposter's event buzzed", emptySet<String>(), buzzes() - buzzedBefore)
            }
        }
    }

    private fun everyEventStoredOnce(emits: List<Emit>, startedMs: Long) {
        assertEquals("what the trusted stand-in was told", List(emits.size) { LinkContract.ACCEPTED }, emits.map { it.status })
        val ids = emits.map { it.id }.toSet()
        val stored = probe.linkEvents().filter { it.id in ids }
        assertEquals("one row per id, in the log's own file", ids.sorted(), stored.map { it.id }.sorted())
        val sent = emits.associate { it.id to it.atMs }
        val kinds = emits.associate { it.id to it.kind }
        assertEquals("the day must carry every contract kind", LOG_KINDS.keys, kinds.values.toSet())
        for (event in stored) {
            assertEquals("source of ${event.id}", "race-timer", event.source)
            assertEquals("the log's kind of ${event.id}", LOG_KINDS[kinds.getValue(event.id)], event.kind)
            assertEquals("at_ms of ${event.id} is race-timer's, verbatim", sent.getValue(event.id), event.atMs)
            assertEquals("the contract object of ${event.id} is verbatim", sent.getValue(event.id), event.sentAtMs)
            val received = event.receivedMs
            assertTrue("${event.id} has no received_ms", received != null)
            assertTrue("${event.id} was received at $received, before race-timer sent it at ${event.atMs}", received!! >= event.atMs)
        }
        assertEquals("refusals of the trusted stand-in", 0, refusals(startedMs, standInUid(), "certificate_not_pinned"))
    }

    /**
     * Criterion 8's buzz with no activity: only the host engine can have fired these, and no plain
     * test sees that engine's channel. `dumpsys vibrator_manager` keeps recent vibrations after
     * they end (cairn android-vibration-usage-and-dnd), so only the lines not in [before] count,
     * and an earlier run's cannot. The resend is in the run, and must not add one. Its tone is not
     * asserted: API 34's audio_flinger keeps about 16 s of tracks, less than this run. It is read in
     * tool/core_host_spike/results/2026-11-02-link-tone.txt instead (#33's review).
     */
    private fun oneBuzzPerStoredEvent(before: Set<String>) {
        // The core answers before the buzz goes out: lib/core_host.dart does not await it.
        probe.await("one buzz per stored event", timeoutMs = 10_000) { (buzzes() - before).size >= DAY_EVENTS }
        Thread.sleep(1_000)
        val buzzed = buzzes() - before
        assertEquals("buzzes for $DAY_EVENTS stored events and one resend: $buzzed", DAY_EVENTS, buzzed.size)
        assertTrue("a buzz did not play: $buzzed", buzzed.all { "finished" in it })
    }

    private fun nothingStoredAndEveryEventRefused(emits: List<Emit>, startedMs: Long) {
        assertEquals("what the imposter was told", List(emits.size) { LinkContract.REFUSED }, emits.map { it.status })
        val ids = emits.map { it.id }.toSet()
        assertEquals("an imposter's events in the log", emptyList<String>(), probe.linkEvents().filter { it.id in ids }.map { it.id })
        assertEquals("refusals for the certificate", emits.size, refusals(startedMs, standInUid(), "certificate_not_pinned"))
    }

    /**
     * The package half of LinkTrust. Both stand-in copies carry the pinned package, so neither can
     * show that a caller with any other package is refused, and the certificate check reads the
     * PINNED package's signer, not the caller's: without this check, any app could send while
     * race-timer is installed. This call is that other app. The host is up, so a no_core here would
     * not be mistaken for the refusal.
     */
    @Test
    fun criterion7_aCallFromTheAppsOwnUidIsRefusedForItsPackage() {
        hostUp()
        val id = "self-${System.nanoTime()}"
        val startedMs = System.currentTimeMillis()

        assertEquals("what another package was told", LinkContract.REFUSED, bindAndSend(linkEvent(id)))

        assertEquals("refusals of the app's own UID", 1, refusals(startedMs, Process.myUid(), "package_not_pinned"))
        assertEquals("another package's event in the log", emptyList<String>(), storedIds(id))
    }

    /**
     * The owner's decision on #33: minSdk stays 24, and below 28 the link is refused, with no weaker
     * path. CI has no such device, so the level is injected. It takes the installed stand-in's UID,
     * because the package check runs first and the app's own UID would never get this far, and the
     * call at 28 is the control that 27 is what refused it.
     */
    @Test
    fun belowApi28TheStandInIsRefusedWhoeverSignedIt() {
        val uid = standInUid()

        assertEquals(LinkTrust.Untrusted("api_below_28"), LinkTrust.check(context, uid, 27))

        val atTheFloor = if (expect == "trusted") LinkTrust.Trusted else LinkTrust.Untrusted("certificate_not_pinned")
        assertEquals(atTheFloor, LinkTrust.check(context, uid, 28))
    }

    /**
     * ADR 004's `no_core`, by both routes. Past the trust check, in this process, and through the
     * stand-in over the real binder path, where the trusted copy reaches the same answer and the
     * imposter never gets that far. Instrumentation is what keeps this process up, so this is the
     * host down in a live process, and link_kill.sh is the process cold-started by the bind. The
     * stand-in's calls must not bring the host up either: LinkService neither starts nor binds it.
     */
    @Test
    fun withNoHostRunningACallAnswersNoCoreAndLeavesTheHostDown() {
        stopHost()
        val id = "down-${System.nanoTime()}"

        assertEquals(LinkContract.NO_CORE, LinkInbox.deliver(linkEvent(id), System.currentTimeMillis()))

        val emits = emit("down-${System.nanoTime()}", count = 3, intervalMs = 100)
        val told = if (expect == "trusted") LinkContract.NO_CORE else LinkContract.REFUSED
        assertEquals("what the stand-in was told with no host", List(3) { told }, emits.map { it.status })
        assertNull("a link call brought the host up", CoreService.live)
        assertTrue("a link call started the core host", !probe.coreHostRunning())
        assertEquals("events answered no_core in the log", emptyList<String>(), storedIds(id, *emits.map { it.id }.toTypedArray()))
    }

    /**
     * ADR 004's bounded wait: `accepted` means committed, so a call nothing answers in time says
     * `no_core`, and stays queued. The main thread is held here because it is the one thing that
     * reliably keeps the core from answering; the call waits behind it, and the release lets it
     * through. race-timer's retry under the same id then reads `accepted` and stores nothing.
     */
    @Test
    fun aCallNothingAnswersInTimeSaysNoCoreStaysQueuedAndItsRetryStoresNothing() {
        hostUp()
        val id = "late-${System.nanoTime()}"
        val event = linkEvent(id)
        val told = System.currentTimeMillis() - 5_000
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            held.countDown()
            release.await(30, TimeUnit.SECONDS)
        }
        try {
            assertTrue("the main thread never came to the hold", held.await(10, TimeUnit.SECONDS))
            assertEquals(LinkContract.NO_CORE, LinkInbox.deliver(event, told, waitMs = 300))
            assertEquals("stored while the main thread was held", emptyList<String>(), storedIds(id))
        } finally {
            release.countDown()
        }

        probe.await("the queued call to commit") { storedIds(id).size == 1 }
        assertEquals(LinkContract.ACCEPTED, LinkInbox.deliver(event, System.currentTimeMillis()))
        assertEquals("rows after the retry", listOf(id), storedIds(id))
        assertEquals("a held event keeps when it arrived", told, probe.linkEvents().single { it.id == id }.receivedMs)
    }

    /**
     * ADR 004's fifth state: a call that lands while the engine starts waits for it, and is stored.
     * LinkService never starts the host, so only the PRO opening the app gets here, and then the
     * window is the engine's start, a few hundred ms. [CoreService.linksHeld] is what says the call
     * took that path: without it, this would pass just as well having missed the state.
     */
    @Test
    fun aCallWhileTheEngineStartsIsHeldAndThenStored() {
        stopHost()
        val id = "held-${System.nanoTime()}"
        val told = System.currentTimeMillis()
        val heldBefore = CoreService.linksHeld
        val answer = AtomicReference<String>()
        val sender = thread {
            val deadline = SystemClock.uptimeMillis() + 30_000
            while (CoreService.live == null && SystemClock.uptimeMillis() < deadline) Thread.sleep(1)
            answer.set(LinkInbox.deliver(linkEvent(id), told, waitMs = 30_000))
        }

        val activity = probe.launch()
        sender.join(60_000)
        probe.destroy(activity)

        assertTrue("the call never had to wait, so this run proved nothing", CoreService.linksHeld > heldBefore)
        assertEquals(LinkContract.ACCEPTED, answer.get())
        assertEquals("rows", listOf(id), storedIds(id))
        assertEquals("it keeps when it arrived", told, probe.linkEvents().single { it.id == id }.receivedMs)
    }

    /** The core up as a PRO starts it: the activity destroyed, the host foreground, its Dart ready. */
    private fun hostUp() {
        val activity = probe.launch()
        probe.await("the core host to go into the foreground") { probe.coreHostForeground() }
        probe.destroy(activity)
        assertTrue("the core host left the foreground with the activity", probe.coreHostForeground())
        // The append answers once the engine has said it is ready, so the first link event cannot
        // meet an engine still starting and use up the wait.
        val (result, data) = probe.appendFromIntent(CoreHostProbe.probe("link-${System.nanoTime()}"))
        assertEquals("the core host never came ready: ${data.getString(CoreService.KEY_CODE)}", CoreService.RESULT_ACCEPTED, result)
    }

    private fun stopHost() {
        context.stopService(Intent(context, CoreService::class.java))
        probe.await("no core host to be running") { CoreService.live == null && !probe.coreHostRunning() }
    }

    /**
     * The steps of tool/core_host_spike/link_run.sh, undone here for the next test and again by the
     * script's trap, because a crash here skips this `finally` and volume_key.sh runs next. What
     * force-idle said goes in the failure, since that is what a refusal looks like.
     */
    private fun inForcedDoze(block: () -> Unit) {
        try {
            device.executeShellCommand("dumpsys battery unplug")
            device.executeShellCommand("input keyevent KEYCODE_SLEEP")
            val forced = device.executeShellCommand("dumpsys deviceidle force-idle").trim()
            assertEquals("forced Doze did not take ($forced)", "IDLE", device.executeShellCommand("dumpsys deviceidle get deep").trim())
            block()
        } finally {
            device.executeShellCommand("dumpsys deviceidle unforce")
            device.executeShellCommand("dumpsys battery reset")
            device.executeShellCommand("input keyevent KEYCODE_WAKEUP")
            device.executeShellCommand("wm dismiss-keyguard")
        }
    }

    /**
     * One run of the stand-in, started through the shell, which is exempt from the background-start
     * rule, and returns its EMIT lines. [resend] sends that event again at the end of the run.
     */
    private fun emit(run: String, count: Int, intervalMs: Int, resend: Int = 0): List<Emit> {
        val started = device.executeShellCommand(
            "am start-foreground-service -n $STAND_IN/$EMIT_SERVICE --es companion ${context.packageName} " +
                "--es mech bound --ei count $count --ei interval_ms $intervalMs --ei resend $resend --es run $run",
        ).trim()
        probe.await("the stand-in to finish $run (am said: $started)", timeoutMs = count * intervalMs + 60_000L) {
            standInLines(run).any { "DONE run=$run " in it }
        }
        return standInLines(run).filter { "EMIT run=$run " in it }.map(::Emit)
    }

    private fun standInLines(run: String) =
        device.executeShellCommand("logcat -d -s LINK:I").lines().filter { "run=$run " in it }

    /**
     * This app's touch-class lines in `dumpsys vibrator_manager`, whatever their status. Each carries
     * its own time, so one vibration is one line. Matched on the package and the usage alone, so
     * as to rest as little as it can on the dump's layout.
     */
    private fun buzzes(): Set<String> =
        device.executeShellCommand("dumpsys vibrator_manager").lineSequence()
            .map { it.trim() }
            .filter { context.packageName in it && it.contains("touch", ignoreCase = true) }
            .toSet()

    private fun standInUid() = context.packageManager.getApplicationInfo(STAND_IN, 0).uid

    private fun storedIds(vararg ids: String): List<String> =
        probe.linkEvents().map { it.id }.filter { it in ids }

    /**
     * Lines since [sinceMs] that say [uid] was refused for [reason], from both of LinkRefusals'
     * files, since the log survives a reinstall and can roll over during a run.
     */
    private fun refusals(sinceMs: Long, uid: Int, reason: String): Int =
        listOf(LinkRefusals.FILE, "${LinkRefusals.FILE}.1")
            .map { File(context.noBackupFilesDir, it) }
            .filter { it.exists() }
            .flatMap { it.readLines() }
            .count { (it.substringBefore(' ').toLongOrNull() ?: 0L) >= sinceMs && it.endsWith(" uid=$uid reason=$reason") }

    private fun linkEvent(id: String) =
        """{"v":1,"id":"$id","kind":"signal","at_ms":${System.currentTimeMillis()},"sequence":"$id"}"""

    /** One transaction on the real LinkService, from this process, as the stand-in makes it from its own. */
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
        assertTrue("LinkService would not bind", context.bindService(Intent(context, LinkService::class.java), connection, Context.BIND_AUTO_CREATE))
        try {
            assertTrue("LinkService never connected", connected.await(10, TimeUnit.SECONDS))
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

    private companion object {
        const val STAND_IN = "io.github.sailordave17.racetimer"

        /** In full: the stand-in's namespace does not move with its package. */
        const val EMIT_SERVICE = "com.procompanion.link_harness.EmitService"

        /** One pass of the stand-in's script (Contract.kt), which covers every contract kind. */
        const val DAY_EVENTS = 15
        const val RESENT_EVENT = 5

        /** ADR 004's map from a contract kind to the log's, the wire's half of link.dart's. */
        val LOG_KINDS = mapOf(
            "sequence_start" to "start.sequence_start",
            "signal" to "start.signal",
            "postponement" to "start.postponement",
            "individual_recall" to "start.individual_recall",
            "general_recall" to "start.general_recall",
            "start" to "start",
        )
    }
}

/**
 * link_kill.sh's reader, a class of its own so that RaceTimerLinkTest's count does not depend on
 * it. The script names every id race-timer's stand-in was told `accepted` for, the re-sent one
 * included, and each must be in the log exactly once. It reads the log's own file, after a kill,
 * and `accepted` alone would be the core's word for it.
 */
class LinkKillReadback {
    @Test
    fun everyIdTheScriptNamesIsInTheLogExactlyOnce() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val ids = InstrumentationRegistry.getArguments().getString("ids")?.split(',')
            ?: throw AssertionError("link_kill.sh passes the ids with -e ids")
        val stored = CoreHostProbe(instrumentation).linkEvents().map { it.id }.filter { it in ids }
        assertEquals("the accepted ids, one row each", ids.sorted(), stored.sorted())
    }
}
