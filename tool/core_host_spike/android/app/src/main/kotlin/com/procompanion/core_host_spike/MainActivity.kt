package com.procompanion.core_host_spike

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The UI's own engine. It asks for the runtime permissions the service needs,
 * POST_NOTIFICATIONS first (Android 13+) and then location, and starts the
 * foreground service while the app is visible, which a `location` service requires.
 * Launched with `autostart=true` it does this without a tap, so an instrumented test
 * can drive the permission dialogs.
 */
class MainActivity : FlutterActivity() {
    private var afterPermissions: (() -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "core_host/ui").setMethodCallHandler { call, result ->
            when (call.method) {
                "startCore" -> { requestThenStart(); result.success(null) }
                "coreRunning" -> result.success(CoreService.running)
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.getBooleanExtra("autostart", false) == true) requestThenStart()
    }

    private fun requestThenStart() {
        val needed = buildList {
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            add(Manifest.permission.ACCESS_FINE_LOCATION)
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isEmpty()) { startCore(); return }
        afterPermissions = { startCore() }
        requestPermissions(needed.toTypedArray(), REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE) return
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
            afterPermissions?.invoke()
        }
        afterPermissions = null
    }

    private fun startCore() {
        startForegroundService(Intent(this, CoreService::class.java))
    }

    companion object { const val REQUEST_CODE = 14 }
}
