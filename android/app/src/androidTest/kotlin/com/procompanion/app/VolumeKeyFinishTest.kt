package com.procompanion.app

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.PowerManager
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.regex.Pattern

/**
 * #19 on a device: the volume-down key against the real app and its real log.
 *
 * Every key here is injected through the input system, the road a hardware
 * press takes: the window manager's policy sees it first, then MainActivity,
 * and whatever MainActivity does not keep goes to the window's fallback, which
 * hands it to the active media session or the suggested stream. A key sent
 * inside Flutter would skip all of that, and with it the handler under test
 * (criterion 8). The app is driven through its accessibility tree, as TalkBack
 * reads it, and a finish is counted off the finish screen's heading.
 *
 * "No volume moved" is not enough on its own. With nothing playing, the first
 * press while the volume panel is hidden only shows the panel and moves no
 * stream (AudioService's suppressAdjustment; measured, music 8 -> 8, then 8 -> 7
 * on a second press 0.8 s later). So the tests also read the audio service's own
 * log of volume-adjust requests: from the finish screen none may arrive at all,
 * and from every other screen one must.
 *
 * Run by integration_test/volume_key.sh, which reads its verdict.
 */
class VolumeKeyFinishTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val context: Context = instrumentation.targetContext
    private val audio = context.getSystemService(AudioManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)

    @Before
    fun openTheApp() {
        device.wakeUp()
        shell("wm dismiss-keyguard")
        // Every stream half way, so a press can be seen to move one either way.
        for (stream in STREAMS) {
            val mid = (audio.getStreamMinVolume(stream) + audio.getStreamMaxVolume(stream) + 1) / 2
            shell("cmd audio set-volume $stream $mid")
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        context.startActivity(launch)
        await(button("FINISHES"))
    }

    @After
    fun stopTheStandIn() {
        shell("am stopservice -n $STAND_IN")
        device.wakeUp()
    }

    @Test
    fun criterion1_onTheFinishScreenOnePressIsOneFinishAndNoVolumeMoves() {
        open("FINISHES")
        val before = finishes()
        val volumes = volumes()
        val requests = volumeRequests()

        press()

        awaitFinishes(before + 1)
        SystemClock.sleep(SETTLE_MS)
        assertEquals("one press, exactly one finish", before + 1, finishes())
        assertNoVolumeRequest(requests)
        assertEquals("no stream's volume moved", volumes, volumes())
    }

    @Test
    fun criterion2_aHeldKeyIsOneFinishAndDistinctPressesAreOneEach() {
        open("FINISHES")
        val before = finishes()
        val volumes = volumes()
        val requests = volumeRequests()

        hold(repeats = 12)
        awaitFinishes(before + 1)
        SystemClock.sleep(SETTLE_MS)
        assertEquals("a held key with 12 repeats is one finish", before + 1, finishes())

        press()
        press()
        awaitFinishes(before + 3)
        SystemClock.sleep(SETTLE_MS)
        assertEquals("two distinct presses are two more", before + 3, finishes())
        assertNoVolumeRequest(requests)
        assertEquals("no stream's volume moved", volumes, volumes())
    }

    @Test
    fun criterion3_onEveryOtherScreenTheKeyLogsNothingAndBehavesNormally() {
        open("FINISHES")
        val before = finishes()
        device.pressBack()
        await(button("FINISHES"))

        assertTheKeyBehavesNormally("home")
        for (screen in listOf("SEQUENCE", "RESULTS", "FLEETS")) {
            open(screen)
            assertTheKeyBehavesNormally(screen)
            device.pressBack()
            await(button("FINISHES"))
        }

        open("FINISHES")
        SystemClock.sleep(SETTLE_MS)
        assertEquals("no finish was logged on another screen", before, finishes())
        // The positive control: the same press here is read as a finish.
        press()
        awaitFinishes(before + 1)
    }

    @Test
    fun criterion4_anotherAppsPlayingSessionKeepsItsVolume() {
        shell("am start-foreground-service -n $STAND_IN")
        awaitStandIn()

        // The control: off the finish screen the stand-in's session takes the
        // key, so its volume, the alarm stream's, is one that can be seen to move.
        val alarm = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        press()
        awaitVolume(AudioManager.STREAM_ALARM, alarm - 1, "the stand-in's session took the key off the finish screen")

        open("FINISHES")
        val before = finishes()
        val volumes = volumes()
        val requests = volumeRequests()
        press()
        awaitFinishes(before + 1)
        SystemClock.sleep(SETTLE_MS)
        assertEquals("the session's volume is unchanged", volumes[AudioManager.STREAM_ALARM],
            audio.getStreamVolume(AudioManager.STREAM_ALARM))
        assertNoVolumeRequest(requests)
        assertEquals("and so is every other stream's", volumes, volumes())
        assertEquals("one finish", before + 1, finishes())
    }

    @Test
    fun criterion5_withTheScreenOffNoFinishIsLogged() {
        open("FINISHES")
        val before = finishes()

        device.sleep()
        awaitTrue("the screen went off") { !power.isInteractive }
        press()
        SystemClock.sleep(SETTLE_MS)
        device.wakeUp()
        shell("wm dismiss-keyguard")
        awaitTrue("the screen came back on") { power.isInteractive }

        SystemClock.sleep(SETTLE_MS)
        assertEquals("a press with the screen off logs nothing", before, finishes())
        // The positive control: screen on again, the same press is a finish.
        press()
        awaitFinishes(before + 1)
    }

    // --- the key --------------------------------------------------------------

    /** One press: a down and its up, as `input keyevent` sends them. */
    private fun press() {
        val down = SystemClock.uptimeMillis()
        inject(KeyEvent.ACTION_DOWN, down)
        inject(KeyEvent.ACTION_UP, down)
    }

    /** A held key: its down, [repeats] key-repeats 50 ms apart, then its up. */
    private fun hold(repeats: Int) {
        val down = SystemClock.uptimeMillis()
        inject(KeyEvent.ACTION_DOWN, down)
        for (i in 1..repeats) {
            SystemClock.sleep(50)
            inject(KeyEvent.ACTION_DOWN, down, repeat = i, flags = if (i == 1) KeyEvent.FLAG_LONG_PRESS else 0)
        }
        inject(KeyEvent.ACTION_UP, down)
    }

    private fun inject(action: Int, downTime: Long, repeat: Int = 0, flags: Int = 0) {
        val event = KeyEvent(
            downTime, SystemClock.uptimeMillis(), action, KeyEvent.KEYCODE_VOLUME_DOWN, repeat, 0,
            KeyCharacterMap.VIRTUAL_KEYBOARD, 0, flags, InputDevice.SOURCE_KEYBOARD,
        )
        assertTrue("the input system took the injected key", instrumentation.uiAutomation.injectInputEvent(event, true))
    }

    // --- the screen -----------------------------------------------------------

    /** A Flutter node by its label, which the accessibility tree may carry as text or description. */
    private fun button(label: String) = listOf(By.desc(label), By.text(label))

    private fun await(selectors: List<BySelector>, timeoutMs: Long = UI_TIMEOUT_MS): UiObject2 {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (true) {
            for (s in selectors) device.findObject(s)?.let { return it }
            check(SystemClock.uptimeMillis() < deadline) { "nothing on screen matches $selectors" }
            SystemClock.sleep(100)
        }
    }

    private fun open(label: String) {
        await(button(label)).click()
        if (label == "FINISHES") await(listOf(By.desc(HEADING), By.text(HEADING)))
        SystemClock.sleep(SETTLE_MS) // the route's push, and with it the arming
    }

    /** The finish screen's heading count: "Finishes · N". */
    private fun finishes(): Int {
        val heading = await(listOf(By.desc(HEADING), By.text(HEADING)))
        val label = heading.contentDescription ?: heading.text
        return HEADING.matcher(label).run { check(matches()) { "heading reads '$label'" }; group(1)!!.toInt() }
    }

    private fun awaitFinishes(n: Int) = awaitTrue("the heading reached $n finishes") { finishes() == n }

    // --- the volumes ----------------------------------------------------------

    private fun volumes(): Map<Int, Int> = STREAMS.associateWith { audio.getStreamVolume(it) }

    /**
     * What "the key behaves normally" means: the press reaches the system's volume handling, and,
     * since with nothing playing that first press may only show the volume panel, a second one
     * lowers a stream a step. None goes up.
     */
    private fun assertTheKeyBehavesNormally(where: String) {
        val before = volumes()
        val requests = volumeRequests()
        press()
        awaitTrue("a press on $where reached the system's volume handling") { (volumeRequests() - requests).isNotEmpty() }
        SystemClock.sleep(PANEL_MS)
        press()
        awaitTrue("a second press on $where lowered a volume") { volumes().any { (s, v) -> v < before.getValue(s) } }
        val after = volumes()
        assertTrue("a press on $where raised no volume: $before -> $after", after.all { (s, v) -> v <= before.getValue(s) })
        for (stream in STREAMS) shell("cmd audio set-volume $stream ${before.getValue(stream)}")
    }

    /**
     * The audio service's own record of volume-adjust requests, each stamped to the millisecond
     * ("10-06 14:00:18:621 adjustSuggestedStreamVolume(… dir:ADJUST_LOWER …) from android/android
     * uid:1000"). A key the system handled shows here even when the volume did not move. The log
     * is a ring, so what is new is compared as a set, never by count.
     */
    private fun volumeRequests(): Set<String> =
        shell("dumpsys audio").lineSequence().filter { ADJUST.containsMatchIn(it) }.map { it.trim() }.toSet()

    private fun assertNoVolumeRequest(before: Set<String>) {
        val new = volumeRequests() - before
        assertTrue("no volume-adjust request reached the audio service, but: $new", new.isEmpty())
    }

    private fun awaitVolume(stream: Int, expected: Int, what: String) =
        awaitTrue("$what: stream $stream at $expected") { audio.getStreamVolume(stream) == expected }

    private fun awaitStandIn() =
        awaitTrue("the stand-in's media session is up") { shell("dumpsys media_session").contains(MediaStandInService.TAG) }

    // --- plumbing -------------------------------------------------------------

    private fun awaitTrue(what: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + UI_TIMEOUT_MS
        while (!condition()) {
            check(SystemClock.uptimeMillis() < deadline) { "timed out: $what" }
            SystemClock.sleep(100)
        }
    }

    private fun shell(command: String): String =
        instrumentation.uiAutomation.executeShellCommand(command).let { fd ->
            android.os.ParcelFileDescriptor.AutoCloseInputStream(fd).bufferedReader().use { it.readText() }
        }

    private companion object {
        // "Finishes · N", or "Finishes · <fleet> · N" once fleets are named (#18).
        val HEADING: Pattern = Pattern.compile("Finishes · (?:.+ · )?(\\d+)")
        val STREAMS = listOf(
            AudioManager.STREAM_VOICE_CALL,
            AudioManager.STREAM_SYSTEM,
            AudioManager.STREAM_RING,
            AudioManager.STREAM_MUSIC,
            AudioManager.STREAM_ALARM,
            AudioManager.STREAM_NOTIFICATION,
            AudioManager.STREAM_ACCESSIBILITY,
        )
        val ADJUST = Regex("""adjust(Suggested)?StreamVolume\(""")
        const val STAND_IN = "com.procompanion.app.test/com.procompanion.app.MediaStandInService"
        const val SETTLE_MS = 1_000L

        // Past AudioService's long-press window (the platform's long-press timeout), inside the
        // volume panel's few seconds on screen.
        const val PANEL_MS = 800L
        const val UI_TIMEOUT_MS = 10_000L
    }
}
