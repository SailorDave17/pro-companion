package com.procompanion.app

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The confirmation buzz and beep (#4): lib/confirmation.dart calls
 * `pro_companion/confirm` once the core has committed an event.
 *
 * The volume key (#19): lib/finish/volume_key.dart arms and disarms it over
 * `pro_companion/volume_key`, and each taken press is sent back as `press`.
 *
 * The core host (#32, ADR 003 decision 5's start sequence): the activity binds
 * CoreService for as long as it lives, and asks for location and notifications
 * while it is visible. Once location is held it starts the service too, which
 * goes into the foreground and keeps logging after the activity is gone.
 */
class MainActivity : FlutterActivity() {
    private val tones = mutableMapOf<Int, ToneGenerator>()
    private val volumeKey = VolumeKeyFinish()
    private var volumeKeyChannel: MethodChannel? = null
    private var coreBound = false

    /** Held only to keep the core host running while the activity lives. */
    private val coreHost = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {}
        override fun onServiceDisconnected(name: ComponentName?) {}
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Bound, the core runs whatever the user grants. lib/core_bootstrap.dart waits for it.
        coreBound = bindService(Intent(this, CoreService::class.java), coreHost, Context.BIND_AUTO_CREATE)
        askForPermissions()
        startCoreHost()
    }

    /**
     * Location "while using the app", never background (ADR 003): FINE and COARSE together, since
     * Android 12+ grants FINE only that way. And on Android 13+ notifications, for the core host's
     * notification. Each is asked whenever it is not held: Android itself stops showing a dialog
     * once the user has refused it twice. Without location every event says `no_permission` and
     * still appends, but only while the activity lives.
     */
    private fun askForPermissions() {
        val ask = buildList {
            if (!holds(Manifest.permission.ACCESS_FINE_LOCATION)) {
                add(Manifest.permission.ACCESS_FINE_LOCATION)
                add(Manifest.permission.ACCESS_COARSE_LOCATION)
            }
            if (Build.VERSION.SDK_INT >= 33 && !holds(Manifest.permission.POST_NOTIFICATIONS)) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (ask.isNotEmpty()) requestPermissions(ask.toTypedArray(), PERMISSIONS_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSIONS_REQUEST) startCoreHost()
    }

    /**
     * Starts the core host while the app is visible, as a `location` service must be started, so
     * that it goes into the foreground. Only with location: without it Android 14 refuses the
     * service's foreground start, and it stays bound to this activity instead. Each start also
     * has the service read location afresh.
     */
    private fun startCoreHost() {
        if (!holds(Manifest.permission.ACCESS_FINE_LOCATION) && !holds(Manifest.permission.ACCESS_COARSE_LOCATION)) return
        try {
            startService(Intent(this, CoreService::class.java))
        } catch (e: IllegalStateException) {
            // Not visible after all (a start from the background): the binding still holds the core.
            Log.w("MainActivity", "could not start the core host: $e")
        }
    }

    private fun holds(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeKeyChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pro_companion/volume_key").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "arm" -> { volumeKey.armed = true; result.success(true) }
                    "disarm" -> { volumeKey.armed = false; result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pro_companion/confirm")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "vibrate" -> { vibrate(); result.success(null) }
                        "tone" -> { tone(call.argument<String>("stream") ?: "notification"); result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("confirm_failed", e.message, null)
                }
            }
    }

    /**
     * Before Flutter or the system sees it: a taken volume-down press never
     * reaches the window's fallback, which is what would hand it to the active
     * media session or the suggested stream. The screen off, nothing is taken
     * (groom decision G4), even a key injected while it is off.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val screenOn = (getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive && hasWindowFocus()
        return when (volumeKey.judge(event, screenOn)) {
            VolumeKeyFinish.Verdict.FINISH -> { volumeKeyChannel?.invokeMethod("press", null); true }
            VolumeKeyFinish.Verdict.SWALLOW -> true
            VolumeKeyFinish.Verdict.PASS -> super.dispatchKeyEvent(event)
        }
    }

    /**
     * One short buzz, declared as touch feedback, which is what it is. On
     * race-timer's API 36 measurements `USAGE_TOUCH` was the class that
     * survived total-silence Do Not Disturb, and `USAGE_ALARM` was dropped
     * without an error (cairn: android-vibration-usage-and-dnd).
     */
    private fun vibrate() {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (!vibrator.hasVibrator()) return
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> vibrator.vibrate(
                VibrationEffect.createOneShot(BUZZ_MS, VibrationEffect.DEFAULT_AMPLITUDE),
                VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH),
            )
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> @Suppress("DEPRECATION") vibrator.vibrate(
                VibrationEffect.createOneShot(BUZZ_MS, VibrationEffect.DEFAULT_AMPLITUDE),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION).build(),
            )
            else -> @Suppress("DEPRECATION") vibrator.vibrate(BUZZ_MS)
        }
    }

    /** One short beep on the stream the user's volume for it controls (#86). */
    private fun tone(stream: String) {
        val streamType = when (stream) {
            "alarm" -> AudioManager.STREAM_ALARM
            "media" -> AudioManager.STREAM_MUSIC
            else -> AudioManager.STREAM_NOTIFICATION
        }
        val generator = tones.getOrPut(streamType) { ToneGenerator(streamType, ToneGenerator.MAX_VOLUME) }
        // A confirmation's length carries no meaning, so ToneGenerator's
        // imprecise durations (cairn: android-tonegenerator-durations) do not matter here.
        generator.startTone(ToneGenerator.TONE_PROP_BEEP, BEEP_MS)
    }

    override fun onDestroy() {
        // Started, the core host stays in the foreground; bound only, it goes with the activity.
        if (coreBound) unbindService(coreHost)
        coreBound = false
        volumeKeyChannel?.setMethodCallHandler(null)
        volumeKeyChannel = null
        volumeKey.armed = false
        tones.values.forEach { it.release() }
        tones.clear()
        super.onDestroy()
    }

    private companion object {
        const val BUZZ_MS = 80L
        const val BEEP_MS = 120
        const val PERMISSIONS_REQUEST = 31
    }
}
