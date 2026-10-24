package com.procompanion.app

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * #32 on a device: the core host against the real app and its real log, with location and
 * notifications granted. Run by integration_test/core_host.sh, which grants both and reads the
 * verdict. CoreHostRefusedTest is the same host with location refused.
 */
class CoreHostTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val probe = CoreHostProbe(instrumentation)

    @Before
    fun wake() {
        device.wakeUp()
        device.executeShellCommand("wm dismiss-keyguard")
    }

    @After
    fun leaveTheShade() {
        device.pressHome()
    }

    @Test
    fun criterion1_withTheActivityDestroyedTheCoreInTheForegroundServiceStillAcceptsAnAppendFromAnIntent() {
        val activity = probe.launch()
        probe.await("the core host to go into the foreground") { probe.coreHostForeground() }
        probe.destroy(activity)
        assertTrue("the core host left the foreground with the activity", probe.coreHostForeground())

        val run = "c1-${System.nanoTime()}"
        val (result, data) = probe.appendFromIntent(CoreHostProbe.probe(run))

        assertEquals(
            "the core host did not accept the append: ${data.getString(CoreService.KEY_CODE)} " +
                "${data.getString(CoreService.KEY_MESSAGE)}",
            CoreService.RESULT_ACCEPTED,
            result,
        )
        val stored = JSONObject(data.getString(CoreService.EXTRA_EVENT)!!)
        assertEquals("probe.core_host", stored.getString("kind"))
        assertEquals(run, stored.getJSONObject("payload").getString("run"))
        assertEquals("the appended event is not in the log's own file", 1, probe.eventsInLog(stored.getString("ulid")))
        assertTrue("the core host left the foreground", probe.coreHostForeground())
    }

    /**
     * ADR 003 decision 4: appends that start the core host cold reach it before its engine has said
     * it is ready, and are held until then rather than dropped. The test above cannot show this: by
     * the time it appends, the activity's bind has long since started the engine. It takes three:
     * Flutter's own channel buffer holds one early message for a handler not yet set, so a single
     * append arrived even with the service's queue removed (measured, #32's mutation round).
     */
    @Test
    fun criterion1_appendsThatStartTheCoreHostColdAreHeldUntilTheCoreIsReady() {
        context.stopService(Intent(context, CoreService::class.java))
        probe.await("no core host to be running") { !probe.coreHostRunning() }

        val runs = (1..3).map { "cold-$it-${System.nanoTime()}" }
        val answers = probe.appendFromIntents(runs.map(CoreHostProbe::probe))

        answers.forEachIndexed { i, (result, data) ->
            assertEquals(
                "cold append ${i + 1} was not accepted: ${data.getString(CoreService.KEY_CODE)} " +
                    "${data.getString(CoreService.KEY_MESSAGE)}",
                CoreService.RESULT_ACCEPTED,
                result,
            )
            val stored = JSONObject(data.getString(CoreService.EXTRA_EVENT)!!)
            assertEquals(runs[i], stored.getJSONObject("payload").getString("run"))
            assertEquals("cold append ${i + 1} is not in the log's own file", 1, probe.eventsInLog(stored.getString("ulid")))
        }
    }

    @Test
    fun criterion4_itsNotificationSaysTheCompanionIsLoggingAndOpensTheApp() {
        val activity = probe.launch()
        probe.await("the core host to go into the foreground") { probe.coreHostForeground() }
        probe.destroy(activity)

        // What Android holds: the core host's ongoing notification, saying so in its text too.
        val posted = context.getSystemService(NotificationManager::class.java).activeNotifications
            .firstOrNull { it.id == CoreService.NOTIFICATION_ID }?.notification
        assertNotNull("the core host posted no notification", posted)
        assertTrue("not the foreground service's notification", posted!!.flags and Notification.FLAG_FOREGROUND_SERVICE != 0)
        assertEquals(
            "Logging continues with the screen off. Tap to open.",
            posted.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
        )

        // What the user does: open the shade, find it, tap it.
        device.openNotification()
        val title = device.wait(Until.findObject(By.text("PRO Companion is logging")), 10_000)
        assertNotNull("the shade shows no notification saying the companion is logging", title)
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        try {
            title.click()
            assertNotNull("tapping the notification did not open the app", instrumentation.waitForMonitorWithTimeout(monitor, 20_000))
        } finally {
            instrumentation.removeMonitor(monitor)
        }
        assertTrue(
            "the app is not on the screen",
            device.wait(Until.hasObject(By.pkg(context.packageName).depth(0)), 10_000),
        )
    }
}
