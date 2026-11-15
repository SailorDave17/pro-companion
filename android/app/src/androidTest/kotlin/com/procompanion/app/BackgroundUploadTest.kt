package com.procompanion.app

import android.database.sqlite.SQLiteDatabase
import android.os.SystemClock
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

/**
 * #52 on a device: events waiting in the core host upload by themselves when the network comes
 * back, with the activity destroyed and nobody opening the app. Run by
 * integration_test/background_upload.sh, which builds the app with a defines file naming the
 * local stack at the emulator's 10.0.2.2, provisions a race day and passes its overall PRO code.
 *
 * The cut is airplane mode, and it is a real one here: the build reaches the stack through the
 * emulator's own network at 10.0.2.2, not adb's reverse forward at 127.0.0.1, which airplane mode
 * leaves up (sync_flow.sh). So the phone's default network goes down and comes back, which is what
 * CoreService's network callback answers. The control on each side is this process's own connect
 * to the stack.
 *
 * Criterion 3, the resume trigger: the network comes back just after a failed try, with the
 * backoff at its 15 s cap, so the backoff's own next run is about 15 s away. The five must be on
 * shore well before that, which only the callback can do. Without it, they go up on the backoff,
 * late, and this turns red (the mutation round, #52's PR).
 */
class BackgroundUploadTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val probe = CoreHostProbe(instrumentation)
    private val args = InstrumentationRegistry.getArguments()
    private val code = args.getString("code").orEmpty()
    private val host = args.getString("host") ?: "10.0.2.2"
    private val port = (args.getString("port") ?: "54421").toInt()

    @Before
    fun wake() {
        airplane(false)
        device.wakeUp()
        device.executeShellCommand("wm dismiss-keyguard")
    }

    @After
    fun signalBack() {
        // Whatever happened, the emulator is left with its network for the next test.
        airplane(false)
        device.pressHome()
    }

    @Test
    fun criteria1and3_withTheActivityDestroyedWaitingEventsGoUpTheMomentTheNetworkComesBack() {
        assertTrue("run by background_upload.sh, which passes the race day's code", code.isNotEmpty())
        assertTrue("the control: the stack is reachable at $host:$port before anything is cut", reachable())

        // A fresh phone joins by its role's code through the app's own screens, and opens its home.
        val activity = probe.launch()
        tap(button("JOIN WITH CODE"))
        val field = device.wait(Until.findObject(By.clazz("android.widget.EditText")), 15_000)
            ?: throw AssertionError("the join screen shows no field for the code")
        field.click()
        field.text = code
        tap(button("JOIN"))
        tap(listOf(By.descStartsWith("OPEN "), By.textStartsWith("OPEN ")), within = 30_000)
        probe.await("the core host to go into the foreground") { probe.coreHostForeground() }

        // The control on the uncut side: an event goes up on its own.
        val control = appendNotes("control", 1)
        probe.await("the control event to reach shore", 60_000) { accepted(control) == 1 }

        // The activity goes, and the core host stays in the foreground with sync in it.
        probe.destroy(activity)
        assertTrue("the core host left the foreground with the activity", probe.coreHostForeground())

        airplane(true)
        probe.await("the control: airplane mode cut the path to the stack", 30_000) { !reachable() }
        val waiting = appendNotes("background", 5)
        // Long enough for the backoff to reach its cap (1, 2, 4, 8, then 15 s).
        SystemClock.sleep(45_000)
        assertEquals("an event went up while cut", 0, accepted(waiting))

        // Just after a failed try, so the backoff's own next run is about 15 s away.
        val failedAt = nextRecordedRun(within = 30_000)
        val told = CoreService.onlineSent
        airplane(false)
        probe.await("CoreService's network callback to tell the host", 15_000) { CoreService.onlineSent > told }
        val toldAt = System.currentTimeMillis()
        assertTrue(
            "inconclusive: the network took ${toldAt - failedAt} ms after the failed try to come back, " +
                "and by 10 s the backoff's own run is too close to tell the two apart",
            toldAt - failedAt < 10_000,
        )
        probe.await("the five waiting events to reach shore", 20_000) { accepted(waiting) == 5 }
        val onShoreAt = System.currentTimeMillis()
        // background_upload.sh prints this line, the run's evidence.
        Log.i(TAG, "after the failed try: told the host at ${toldAt - failedAt} ms, all five on shore at ${onShoreAt - failedAt} ms")

        assertTrue(
            "the five reached shore ${onShoreAt - failedAt} ms after the failed try: the backoff's run " +
                "is 15 s after it, so this was the backoff and not the network coming back",
            onShoreAt - failedAt < 13_000,
        )
        assertTrue("the core host left the foreground", probe.coreHostForeground())
    }

    private fun airplane(on: Boolean) {
        device.executeShellCommand("cmd connectivity airplane-mode ${if (on) "enable" else "disable"}")
    }

    /** Whether this process can open a connection to the stack's API right now. */
    private fun reachable(): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(host, port), 2_000) }
        true
    } catch (e: java.io.IOException) {
        false
    }

    /** Appends [n] notes from intents, as the activity is gone, and returns their ULIDs. */
    private fun appendNotes(tag: String, n: Int): List<String> {
        val answers = probe.appendFromIntents((1..n).map { note("$tag $it ${System.nanoTime()}") })
        return answers.mapIndexed { i, (result, data) ->
            assertEquals(
                "append ${i + 1} was not accepted: ${data.getString(CoreService.KEY_CODE)} " +
                    "${data.getString(CoreService.KEY_MESSAGE)}",
                CoreService.RESULT_ACCEPTED,
                result,
            )
            JSONObject(data.getString(CoreService.EXTRA_EVENT)!!).getString("ulid")
        }
    }

    /** How many of [ulids] the server has accepted, read from the log's own file. */
    private fun accepted(ulids: List<String>): Int = db { db ->
        db.rawQuery(
            "SELECT count(*) FROM upload_outcome WHERE outcome = 'accepted' AND ulid IN (${ulids.joinToString { "?" }})",
            ulids.toTypedArray(),
        ).use { c ->
            c.moveToFirst()
            c.getInt(0)
        }
    }

    /** Waits for sync to record its next run, and returns when that run was. */
    private fun nextRecordedRun(within: Long): Long {
        val before = lastRun()?.getLong("at")
        var at: Long? = null
        probe.await("sync's next run", within) {
            val run = lastRun()
            if (run != null && run.getLong("at") != before) at = run.getLong("at")
            at != null
        }
        return at!!
    }

    private fun lastRun(): JSONObject? = db { db ->
        db.rawQuery("SELECT value FROM meta WHERE key = 'upload_run'", null).use { c ->
            if (c.moveToFirst()) JSONObject(c.getString(0)) else null
        }
    }

    private fun <T> db(read: (SQLiteDatabase) -> T): T =
        SQLiteDatabase.openDatabase(File(context.filesDir, "core.db").path, null, SQLiteDatabase.OPEN_READONLY).use(read)

    private fun button(label: String) = listOf(By.desc(label), By.text(label))

    /**
     * Taps the first of [selectors] on screen. The role picker and the join screen run past the fold
     * on a 320 x 640 phone, so each miss scrolls the screen up a little before looking again.
     */
    private fun tap(selectors: List<BySelector>, within: Long = 15_000) {
        val deadline = SystemClock.uptimeMillis() + within
        while (SystemClock.uptimeMillis() < deadline) {
            val found: UiObject2? = selectors.firstNotNullOfOrNull { device.findObject(it) }
            if (found != null) {
                found.click()
                SystemClock.sleep(500)
                return
            }
            val x = device.displayWidth / 2
            device.swipe(x, device.displayHeight * 3 / 4, x, device.displayHeight / 3, 20)
            SystemClock.sleep(400)
        }
        throw AssertionError("nothing on screen matched $selectors within $within ms")
    }

    private companion object {
        const val TAG = "BackgroundUpload"

        /** A note's wire form, as a tap on the phone would append it. */
        fun note(text: String) =
            """{"kind":"note","source":"tap","payload":{"text":"$text"},"payload_version":1,""" +
                """"person":null,"role":null,"corrects_ulid":null}"""
    }
}
