package com.procompanion.core_host_spike

import android.Manifest
import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** #14 criterion 2: with the activity destroyed, an intent reaches the headless Dart core. */
@RunWith(AndroidJUnit4::class)
class IntentReachesHeadlessDartTest {
    @get:Rule
    val permissions: GrantPermissionRule = GrantPermissionRule.grant(
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.POST_NOTIFICATIONS,
    )

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val log = File(context.filesDir, "core_tick.log")

    @After
    fun stopCore() {
        context.stopService(Intent(context, CoreService::class.java))
    }

    @Test
    fun intentReachesHeadlessDartAfterTheActivityIsDestroyed() {
        log.delete()
        // A location service must be started while the app is visible.
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { it.startForegroundService(Intent(it, CoreService::class.java)) }
        waitFor("the headless core to start") { log.exists() && log.readText().contains(" START") }

        scenario.close() // destroys the activity; the service and its engine must survive
        assertTrue("service stopped with the activity", CoreService.running)

        val token = "intent-${System.nanoTime()}"
        context.startService(Intent(context, CoreService::class.java).putExtra(CoreService.EXTRA_PAYLOAD, token))
        waitFor("the headless core to write $token") { log.readText().contains("INTENT $token") }
    }

    private fun waitFor(what: String, timeoutMs: Long = 60_000, check: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (runCatching(check).getOrDefault(false)) return
            Thread.sleep(250)
        }
        throw AssertionError("timed out waiting for $what; log was:\n${runCatching { log.readText() }.getOrDefault("<absent>")}")
    }
}
