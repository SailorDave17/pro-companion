package com.procompanion.app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import kotlin.math.ceil

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
 * Since #32 CoreService runs it, on the core host's engine, so it keeps
 * reporting with the activity gone. The activity's start of the service after
 * a permission answer is what restarts it.
 *
 * Since #55 it also reports the satellites' time, `{gps_time_ms,
 * device_time_ms, uncertainty_ms}`, from a second listener on the GPS provider:
 * Android guarantees only a GPS-provider fix's time comes from the satellite
 * constellation's clock, and a fused fix's time is usually the phone's own. The
 * fused request above already keeps GNSS on, so it should cost little more, but
 * that is reasoned, not measured: #127 measures the host's battery with both.
 * And `{clock_changed: true}` when the phone's clock is set, because the offset
 * the core holds was measured against the clock as it was; the core logs it.
 */
class LocationFeed(context: Context) : EventChannel.StreamHandler, LocationListener {
    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var sink: EventChannel.EventSink? = null
    private var listening = false
    private var timing = false
    private var watchingClock = false

    /** GPS-provider fixes, read for their time only: the position comes from [onLocationChanged]. */
    private val gnssTime = object : LocationListener {
        override fun onLocationChanged(location: Location) = reportGpsTime(location)

        override fun onProviderEnabled(provider: String) {}

        override fun onProviderDisabled(provider: String) {}

        @Deprecated("Called only below API 29")
        @Suppress("DEPRECATION")
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
    }

    /** The phone's clock was set, by hand or by network time. */
    private val clockSet = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_TIME_CHANGED) sink?.success(mapOf("clock_changed" to true))
        }
    }

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
        if (timing) manager.removeUpdates(gnssTime)
        timing = false
        if (watchingClock) appContext.unregisterReceiver(clockSet)
        watchingClock = false
    }

    private fun start() {
        if (sink == null) return
        watchClock()
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
        timeFromSatellites()
    }

    /** A phone with no GPS provider, or with coarse location only, reports no satellite time; the core then says why. */
    private fun timeFromSatellites() {
        if (!manager.allProviders.contains(LocationManager.GPS_PROVIDER)) return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val request = LocationRequest.Builder(INTERVAL_MS).setQuality(LocationRequest.QUALITY_HIGH_ACCURACY).build()
                manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, request, appContext.mainExecutor, gnssTime)
            } else {
                manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, INTERVAL_MS, 0f, gnssTime, Looper.getMainLooper())
            }
            timing = true
        } catch (e: SecurityException) {
            // Coarse location only: the position still comes from the fused provider.
        }
    }

    private fun watchClock() {
        if (watchingClock) return
        val filter = IntentFilter(Intent.ACTION_TIME_CHANGED)
        // A system broadcast reaches a receiver that is not exported.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(clockSet, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(clockSet, filter)
        }
        watchingClock = true
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

    /**
     * The fix's satellite time, and the phone's clock at that fix: the clock read now, less the fix's
     * age by elapsed realtime, which keeps counting while the CPU sleeps. Both are read here together,
     * so the offset does not depend on how long the report takes to reach the core. Each of the two
     * millisecond readings, and the fix's own millisecond time, can lose under 1 ms, so the
     * uncertainty is the platform's figure for the fix's timestamp plus [READING_MS]. With no figure
     * from the platform it is null: no precision is claimed that the phone did not state.
     */
    private fun reportGpsTime(location: Location) {
        val nowMs = System.currentTimeMillis()
        val ageNs = (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos).coerceAtLeast(0)
        val uncertaintyMs =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && location.hasElapsedRealtimeUncertaintyNanos()) {
                ceil(location.elapsedRealtimeUncertaintyNanos / 1_000_000.0).toLong() + READING_MS
            } else {
                null
            }
        sink?.success(
            mapOf(
                "gps_time_ms" to location.time,
                "device_time_ms" to nowMs - ageNs / 1_000_000,
                "uncertainty_ms" to uncertaintyMs,
            ),
        )
    }

    private companion object {
        /** What the fix's time and the two clock readings can lose between them, in milliseconds. */
        const val READING_MS = 2L
        /** A fix every 5 s while one is to be had: well inside the 30 s a fix counts as current (#31). */
        const val INTERVAL_MS = 5_000L
        const val NO_PERMISSION = "no_permission"
        const val LOCATION_OFF = "location_off"
        const val NO_FIX = "no_fix"
    }
}
