package com.procompanion.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * #32 with location refused. integration_test/core_host.sh revokes it before this runs: a runtime
 * permission can be revoked only from outside the app, since revoking one kills the app's process.
 *
 * Android 14 refuses a `location` foreground service without location, as it refused the sticky
 * restart in #15's probe (ADR 003, amended 2026-10-06). Each test here meets that refusal, and
 * passes only if the core host catches it: an uncaught one crashes this process, which ends the
 * run with no verdict at all.
 */
class CoreHostRefusedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val probe = CoreHostProbe(instrumentation)

    @Before
    fun locationIsRefused() {
        assumeTrue("Android 14 is where a location service without location is refused", Build.VERSION.SDK_INT >= 34)
        for (p in listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) {
            assertEquals("$p must start refused (core_host.sh revokes it)", PackageManager.PERMISSION_DENIED, context.checkSelfPermission(p))
        }
        device.wakeUp()
        device.executeShellCommand("wm dismiss-keyguard")
    }

    /** Decision 3 of the pickup: without location the core still runs, while the activity lives. */
    @Test
    fun withTheActivityTheCoreRunsBoundOutOfTheForegroundAndGoesWithIt() {
        val activity = probe.launch()
        probe.await("the activity to bind the core host") { probe.coreHostRunning() }

        // The activity's location dialog is up. This start is refused its foreground, and the
        // append still reaches the core the activity holds bound.
        val (result, data) = probe.appendFromIntent(CoreHostProbe.probe("refused-bound-${System.nanoTime()}"))
        assertEquals(
            "the bound core did not accept the append: ${data.getString(CoreService.KEY_CODE)}",
            CoreService.RESULT_ACCEPTED,
            result,
        )
        val ulid = JSONObject(data.getString(CoreService.EXTRA_EVENT)!!).getString("ulid")
        assertEquals("the appended event is not in the log's own file", 1, probe.eventsInLog(ulid))
        assertFalse("the core host is in the foreground without location", probe.coreHostForeground())

        probe.destroy(activity)
        probe.await("the core host to go with the activity") { !probe.coreHostRunning() }
    }

    /**
     * ADR 003's amendment: a start whose startForeground is refused stops the host and leaves the
     * process up, and whatever reached the process hears that no core is there.
     */
    @Test
    fun withNoActivityARefusedStartStopsTheHostLeavesTheProcessAndAnswersNoCore() {
        probe.await("no core host to be running") { !probe.coreHostRunning() }

        val (result, _) = probe.appendFromIntent(CoreHostProbe.probe("refused-unbound-${System.nanoTime()}"))
        assertEquals("a refused start must answer no_core", CoreService.RESULT_NO_CORE, result)
        probe.await("the refused core host to stop") { !probe.coreHostRunning() }

        // Refused again the same way: no crash loop, and nothing left running behind it.
        val (again, _) = probe.appendFromIntent(CoreHostProbe.probe("refused-again-${System.nanoTime()}"))
        assertEquals("a second refused start must answer no_core too", CoreService.RESULT_NO_CORE, again)
        probe.await("the refused core host to stop again") { !probe.coreHostRunning() }
    }
}
