package com.procompanion.core_host_spike

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern

/**
 * #14 criterion 3: on Android 13+ the first start requests POST_NOTIFICATIONS and shows
 * the ongoing notification. Needs the permissions revoked first (run_tests.sh does
 * that): revoking one from inside the test would kill this process.
 */
@RunWith(AndroidJUnit4::class)
class NotificationPermissionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)

    @After
    fun stopCore() {
        context.stopService(Intent(context, CoreService::class.java))
    }

    @Test
    fun firstStartRequestsNotificationsAndShowsTheOngoingNotification() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        assertEquals(
            "POST_NOTIFICATIONS must start ungranted (run_tests.sh revokes it)",
            PackageManager.PERMISSION_DENIED,
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS),
        )

        val launch = Intent(context, MainActivity::class.java).putExtra("autostart", true)
        ActivityScenario.launch<MainActivity>(launch).use {
            // Android orders the dialogs itself (location came first on API 36, whatever the
            // request order) and ships the controller as com.google.android.permissioncontroller
            // on Play images, so match ids by suffix and accept dialogs in any order.
            val allow = By.res(Pattern.compile(".*:id/permission_allow(_foreground_only)?_button"))
            val titles = mutableListOf<String>()
            repeat(3) {
                val button = device.wait(Until.findObject(allow), 10_000) ?: return@repeat
                titles += device.findObject(By.res(Pattern.compile(".*:id/permission_message")))?.text ?: "?"
                button.click()
                device.waitForIdle()
            }
            // A dialog asking to send notifications is the proof POST_NOTIFICATIONS was requested.
            assertTrue(
                "no notification-permission dialog among $titles",
                titles.any { it.contains("notification", ignoreCase = true) },
            )

            val nm = context.getSystemService(NotificationManager::class.java)
            val deadline = System.currentTimeMillis() + 20_000
            var ongoing: Notification? = null
            while (ongoing == null && System.currentTimeMillis() < deadline) {
                ongoing = nm.activeNotifications.firstOrNull { it.id == CoreService.NOTIFICATION_ID }?.notification
                if (ongoing == null) Thread.sleep(250)
            }
            assertNotNull("no ongoing notification from the core service", ongoing)
            assertTrue("notification is not ongoing", ongoing!!.flags and Notification.FLAG_ONGOING_EVENT != 0)
            assertEquals(
                PackageManager.PERMISSION_GRANTED,
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS),
            )
        }
    }
}
