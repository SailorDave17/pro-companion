package com.procompanion.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel

/**
 * Where the phone is (#31): the platform half of the position the core stamps
 * on every event. lib/location/location_feed.dart listens on
 * `pro_companion/location` and hands each report to the core. A report is one
 * map: a fix, `{lat, lon, accuracy_m, age_ms}` with `accuracy_m` null when
 * the phone gave none, or no fix, `{reason}`, one of `no_permission`,
 * `location_off` and `no_fix` (the core's GpsReasons).
 *
 * Framework LocationManager only, no Play Services: the fused provider where
 * the phone has one (API 31+), GPS otherwise. A fix's age is read against its
 * own elapsed-realtime stamp, so the phone's last known fix, however old, is
 * reported with its true age and never as current.
 *
 * #32 moves the core into the foreground service, and this moves with it.
 */
class LocationFeed(context: Context) : EventChannel.StreamHandler, LocationListener {
    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var sink: EventChannel.EventSink? = null
    private var listening = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        start()
    }

    override fun onCancel(arguments: Any?) {
        stop()
        sink = null
    }

    /** Starts over, from whatever the phone allows now: after a permission answer. */
    fun restart() {
        stop()
        start()
    }

    fun stop() {
        if (listening) manager.removeUpdates(this)
        listening = false
    }

    private fun start() {
        if (sink == null) return
        if (!permitted()) return reportNone(NO_PERMISSION)
        val provider = provider() ?: return reportNone(NO_FIX)
        try {
            when {
                !locationOn(provider) -> reportNone(LOCATION_OFF)
                else -> manager.getLastKnownLocation(provider)?.let(::reportFix) ?: reportNone(NO_FIX)
            }
            // Registered even with location off: onProviderEnabled then says so.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // High accuracy, or the fused provider stays at BALANCED, which never turns GPS on.
                // On the water GPS is the only source there is. Measured on #31's emulator: at
                // BALANCED, 0 locations reached the app after a geo fix.
                val request = LocationRequest.Builder(INTERVAL_MS).setQuality(LocationRequest.QUALITY_HIGH_ACCURACY).build()
                manager.requestLocationUpdates(provider, request, appContext.mainExecutor, this)
            } else {
                manager.requestLocationUpdates(provider, INTERVAL_MS, 0f, this, Looper.getMainLooper())
            }
            listening = true
        } catch (e: SecurityException) {
            reportNone(NO_PERMISSION)
        }
    }

    private fun permitted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            appContext.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            appContext.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun provider(): String? = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && manager.hasProvider(LocationManager.FUSED_PROVIDER) ->
            LocationManager.FUSED_PROVIDER
        manager.allProviders.contains(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
        manager.allProviders.contains(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
        else -> null
    }

    private fun locationOn(provider: String): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.isLocationEnabled else manager.isProviderEnabled(provider)

    override fun onLocationChanged(location: Location) = reportFix(location)

    override fun onProviderEnabled(provider: String) = reportNone(NO_FIX)

    override fun onProviderDisabled(provider: String) = reportNone(LOCATION_OFF)

    @Deprecated("Called only below API 29; the status it carries is read from the provider callbacks instead")
    @Suppress("DEPRECATION")
    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}

    private fun reportFix(location: Location) {
        val ageMs = (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000
        sink?.success(
            mapOf(
                "lat" to location.latitude,
                "lon" to location.longitude,
                "accuracy_m" to if (location.hasAccuracy()) location.accuracy.toDouble() else null,
                "age_ms" to ageMs.coerceAtLeast(0),
            ),
        )
    }

    private fun reportNone(reason: String) {
        sink?.success(mapOf("reason" to reason))
    }

    private companion object {
        /** A fix every 5 s while one is to be had: well inside the 30 s a fix counts as current (#31). */
        const val INTERVAL_MS = 5_000L
        const val NO_PERMISSION = "no_permission"
        const val LOCATION_OFF = "location_off"
        const val NO_FIX = "no_fix"
    }
}
