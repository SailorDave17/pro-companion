package com.procompanion.core_host_spike

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * #14 spike: a foreground service of type `location` that owns its own FlutterEngine
 * and runs the headless Dart entry point `coreMain`, which has no widget tree. The
 * engine lives here, not in the activity, so destroying the activity leaves it running.
 *
 * Intents carrying a `payload` extra are forwarded to Dart on the
 * `core_host/intents` channel. They are queued until Dart says it is ready, so none
 * is dropped while the engine starts.
 */
class CoreService : Service() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var dartReady = false
    private val pending = ArrayDeque<String>()

    override fun onCreate() {
        super.onCreate()
        goForeground()
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val e = FlutterEngine(applicationContext)
        val ch = MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    result.success(filesDir.absolutePath)
                    dartReady = true
                    while (pending.isNotEmpty()) ch.invokeMethod("intent", pending.removeFirst())
                }
                else -> result.notImplemented()
            }
        }
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "coreMain")
        )
        engine = e
        channel = ch
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(EXTRA_PAYLOAD)?.let { payload ->
            if (dartReady) channel?.invokeMethod("intent", payload) else pending.addLast(payload)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running = false
        engine?.destroy()
        engine = null
        super.onDestroy()
    }

    private fun goForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(NOTIFICATION_CHANNEL, "Race day core", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL)
            .setContentTitle("PRO Companion is running")
            .setContentText("Logging continues with the screen off")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val CHANNEL = "core_host/intents"
        const val EXTRA_PAYLOAD = "payload"
        const val NOTIFICATION_CHANNEL = "core"
        const val NOTIFICATION_ID = 14
        @Volatile var running = false
    }
}
