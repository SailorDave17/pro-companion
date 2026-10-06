package com.procompanion.link_harness

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

/**
 * #15: emits one run of link events, as race-timer would while it runs a sequence:
 * from a foreground service, holding a partial wake lock, on a fixed schedule.
 *
 *   adb shell am start-foreground-service -n com.procompanion.link_harness/.EmitService \
 *     --es mech provider --ei count 50 --ei interval_ms 5000 --es run <id>
 *
 * Every emission is logged under the tag LINK as `EMIT run=… mech=… n=… status=…`, and
 * the run ends with `DONE …`. link_report.dart reads them beside the companion's lines.
 */
class EmitService : Service() {
    private lateinit var worker: HandlerThread
    private lateinit var handler: Handler

    override fun onCreate() {
        super.onCreate()
        worker = HandlerThread("link-emit").apply { start() }
        handler = Handler(worker.looper)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        val mech = intent?.getStringExtra("mech") ?: "provider"
        val count = intent?.getIntExtra("count", 50) ?: 50
        val intervalMs = (intent?.getIntExtra("interval_ms", 5000) ?: 5000).toLong()
        val run = intent?.getStringExtra("run") ?: "r${System.currentTimeMillis()}"
        handler.post {
            emit(mech, count, intervalMs, run)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun emit(mech: String, count: Int, intervalMs: Long, run: String) {
        val power = getSystemService(PowerManager::class.java)
        val lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "linkharness:emit")
        lock.acquire(count * intervalMs + 60_000)
        Log.i(TAG, "BEGIN run=$run mech=$mech count=$count interval_ms=$intervalMs sdk=${Build.VERSION.SDK_INT} idle=${power.isDeviceIdleMode}")
        val script = EventScript(run)
        var ok = 0
        var refused = 0
        var errors = 0
        val emitter = runCatching { emitterFor(this, mech) }
            .onFailure { Log.e(TAG, "no emitter for $mech", it) }
            .getOrNull()
        try {
            val start = SystemClock.elapsedRealtime()
            for (n in 1..count) {
                val wait = start + (n - 1) * intervalMs - SystemClock.elapsedRealtime()
                if (wait > 0) SystemClock.sleep(wait)
                val emitNs = SystemClock.elapsedRealtimeNanos()
                val e = script.event(n, emitNs)
                val status = try {
                    emitter?.send(e.json) ?: "error:no_emitter"
                } catch (t: Throwable) {
                    "error:${t.javaClass.simpleName}:${t.message}"
                }.replace(Regex("\\s+"), "_")
                val sendUs = (SystemClock.elapsedRealtimeNanos() - emitNs) / 1000
                when (status) {
                    "accepted", "sent" -> ok++
                    "refused" -> refused++
                    else -> errors++
                }
                Log.i(TAG, "EMIT run=$run mech=$mech n=$n id=${e.id} kind=${e.kind} status=$status send_us=$sendUs idle=${power.isDeviceIdleMode}")
            }
        } finally {
            emitter?.close()
            lock.release()
        }
        Log.i(TAG, "DONE run=$run mech=$mech emitted=$count ok=$ok refused=$refused errors=$errors idle=${power.isDeviceIdleMode}")
    }

    override fun onDestroy() {
        worker.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun goForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Link harness", NotificationManager.IMPORTANCE_LOW))
        val notification = Notification.Builder(this, CHANNEL)
            .setContentTitle("Link harness is emitting")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val TAG = "LINK"
        const val CHANNEL = "harness"
        const val NOTIFICATION_ID = 15
    }
}
