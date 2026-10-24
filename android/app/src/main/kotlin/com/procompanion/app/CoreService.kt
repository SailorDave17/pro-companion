package com.procompanion.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.ResultReceiver
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The core host (ADR 003, #32): a `location` foreground service that owns a FlutterEngine of its
 * own, running lib/core_host.dart's `coreMain` with no widget tree. The log is opened there and not in the
 * activity's engine, so destroying the activity leaves it logging. The UI engine reaches it over an
 * isolate port (lib/core_bootstrap.dart, lib/core_host.dart), and the location feed (#31) runs here,
 * on this engine, so events appended with the UI gone carry a current position.
 *
 * Two ways in, with two lifetimes:
 * - MainActivity binds it for as long as the activity lives, so the core runs whatever the user
 *   granted. Bound only, the service is not in the foreground and goes with the activity.
 * - MainActivity starts it once location is granted. Only then does it go into the foreground and
 *   outlive the UI: Android 14 refuses a `location` foreground service without location.
 *
 * A start whose startForeground is refused stops itself and leaves the process running (ADR 003,
 * amended 2026-10-06). The sticky restart is refused that way when another component reaches the
 * process first, and an uncaught refusal crashed the process, then every restart after it. Unbound,
 * the engine never starts then, so whatever reached the process answers for itself, as the
 * race-timer link answers `no_core` (#33, ADR 004).
 *
 * An intent with [ACTION_APPEND] carries an event's wire form as JSON in [EXTRA_EVENT], and may
 * carry a [ResultReceiver] in [EXTRA_REPLY], which hears [RESULT_ACCEPTED] with the stored event,
 * [RESULT_REFUSED] with the core's code, or [RESULT_NO_CORE]. The service is not exported, so only
 * this app's own process can send one.
 */
class CoreService : Service() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var location: LocationFeed? = null
    private var dartReady = false
    private var foreground = false

    /** Appends that arrived while the engine started, held until Dart says it is ready. */
    private val pending = ArrayDeque<Intent>()

    override fun onBind(intent: Intent?): IBinder {
        startEngine()
        return Binder()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val started = goForeground()
        if (started) {
            startEngine()
            // The activity starts the service again after a permission answer.
            location?.restart()
        } else {
            stopSelf(startId)
        }
        if (intent?.action == ACTION_APPEND) {
            if (engine != null) append(intent) else reply(intent, RESULT_NO_CORE, Bundle())
        }
        return if (started) START_STICKY else START_NOT_STICKY
    }

    override fun onDestroy() {
        location?.stop()
        location = null
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        dartReady = false
        foreground = false
        while (pending.isNotEmpty()) reply(pending.removeFirst(), RESULT_NO_CORE, Bundle())
        super.onDestroy()
    }

    private fun startEngine() {
        if (engine != null) return
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val e = FlutterEngine(applicationContext)
        val feed = LocationFeed(this)
        EventChannel(e.dartExecutor.binaryMessenger, LOCATION_CHANNEL).setStreamHandler(feed)
        val ch = MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            if (call.method == "ready") {
                result.success(null)
                dartReady = true
                while (pending.isNotEmpty()) send(pending.removeFirst())
            } else {
                result.notImplemented()
            }
        }
        // By library as well as name: in an integration test the root library is the test's file.
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRY_LIBRARY, ENTRY_POINT),
        )
        engine = e
        channel = ch
        location = feed
    }

    /** Main thread only: the channel belongs to the platform thread. */
    private fun append(intent: Intent) {
        if (dartReady) send(intent) else pending.addLast(intent)
    }

    private fun send(intent: Intent) {
        val ch = channel ?: return reply(intent, RESULT_NO_CORE, Bundle())
        val event = intent.getStringExtra(EXTRA_EVENT)
            ?: return reply(intent, RESULT_REFUSED, refusal("malformed", "no $EXTRA_EVENT extra"))
        ch.invokeMethod("append", event, object : MethodChannel.Result {
            override fun success(result: Any?) =
                reply(intent, RESULT_ACCEPTED, Bundle().apply { putString(EXTRA_EVENT, result as String?) })

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                reply(intent, RESULT_REFUSED, refusal(errorCode, errorMessage))

            override fun notImplemented() = reply(intent, RESULT_REFUSED, refusal("not_implemented", null))
        })
    }

    private fun refusal(code: String, message: String?) =
        Bundle().apply { putString(KEY_CODE, code); putString(KEY_MESSAGE, message) }

    private fun reply(intent: Intent, result: Int, data: Bundle) {
        val receiver = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_REPLY, ResultReceiver::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra<ResultReceiver>(EXTRA_REPLY)
        }
        receiver?.send(result, data)
    }

    /** True once the service is in the foreground; false when Android refused it. */
    private fun goForeground(): Boolean {
        if (foreground) return true
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException and its kin: a start from the background.
            return refused(e)
        } catch (e: SecurityException) {
            // A location service without location, or started from the background with it.
            return refused(e)
        }
        foreground = true
        return true
    }

    private fun refused(e: RuntimeException): Boolean {
        Log.w(TAG, "startForeground refused, so the core host stops and the process stays: $e")
        return false
    }

    /** "PRO Companion is logging", which opens the app the way its launcher icon does. */
    private fun notification(): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(NOTIFICATION_CHANNEL, "Race-day logging", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while PRO Companion keeps logging with the app closed"
                },
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName)!!,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        builder.setContentTitle("PRO Companion is logging")
            .setContentText("Logging continues with the screen off. Tap to open.")
            // Drawn from its alpha channel alone, so a framework glyph rather than the launcher icon.
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setContentIntent(open)
        // Shown at once, not after Android 12's ten-second grace for a foreground service.
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return builder.build()
    }

    companion object {
        const val ACTION_APPEND = "com.procompanion.app.action.APPEND"
        const val EXTRA_EVENT = "event"
        const val EXTRA_REPLY = "reply"
        const val KEY_CODE = "code"
        const val KEY_MESSAGE = "message"
        const val RESULT_ACCEPTED = 0
        const val RESULT_REFUSED = 1
        const val RESULT_NO_CORE = 2
        const val NOTIFICATION_ID = 32
        private const val CHANNEL = "pro_companion/core_host"
        private const val LOCATION_CHANNEL = "pro_companion/location"
        private const val NOTIFICATION_CHANNEL = "core"
        private const val ENTRY_LIBRARY = "package:pro_companion/core_host.dart"
        private const val ENTRY_POINT = "coreMain"
        private const val TAG = "CoreService"
    }
}
