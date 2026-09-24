package com.procompanion.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The confirmation buzz and beep (#4): lib/confirmation.dart calls
 * `pro_companion/confirm` once the core has committed an event.
 */
class MainActivity : FlutterActivity() {
    private val tones = mutableMapOf<Int, ToneGenerator>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        tones.values.forEach { it.release() }
        tones.clear()
        super.onDestroy()
    }

    private companion object {
        const val BUZZ_MS = 80L
        const val BEEP_MS = 120
    }
}
