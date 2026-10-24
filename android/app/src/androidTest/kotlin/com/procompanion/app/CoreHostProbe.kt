package com.procompanion.app

import android.app.Activity
import android.app.ActivityManager
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Bundle
import android.os.ResultReceiver
import android.os.SystemClock
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * What CoreHostTest and CoreHostRefusedTest (#32) read and do: the app's own view of its core
 * host, an append sent the way an intent sends it, and the log's own file.
 */
class CoreHostProbe(private val instrumentation: Instrumentation) {
    private val context: Context = instrumentation.targetContext
    private val activities = context.getSystemService(ActivityManager::class.java)

    /** Launches the app as its launcher icon does, and returns the activity it opened. */
    fun launch(): Activity {
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        try {
            context.startActivity(
                context.packageManager.getLaunchIntentForPackage(context.packageName)!!
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
            return instrumentation.waitForMonitorWithTimeout(monitor, 30_000)
                ?: throw AssertionError("the app's activity never opened")
        } finally {
            instrumentation.removeMonitor(monitor)
        }
    }

    /** Finishes [activity] and waits until Android has destroyed it. */
    fun destroy(activity: Activity) {
        instrumentation.runOnMainSync { activity.finish() }
        await("the activity to be destroyed") { activity.isDestroyed }
    }

    /** The core host, as Android reports the app's own services: started or bound. */
    private fun coreHost(): ActivityManager.RunningServiceInfo? =
        @Suppress("DEPRECATION")
        activities.getRunningServices(Int.MAX_VALUE).firstOrNull { it.service.className == CoreService::class.java.name }

    fun coreHostRunning() = coreHost() != null

    fun coreHostForeground() = coreHost()?.foreground == true

    /**
     * Sends [event], an event's wire form as JSON, to the core host as an append intent, and
     * returns the answer: one of CoreService's RESULT_ codes, and what came with it.
     */
    fun appendFromIntent(event: String): Pair<Int, Bundle> = appendFromIntents(listOf(event)).single()

    /**
     * Sends every one of [events] before waiting for any answer, so they can all reach the core host
     * before its engine is ready, and returns the answers in the order sent.
     */
    fun appendFromIntents(events: List<String>): List<Pair<Int, Bundle>> {
        val replies = events.map { event ->
            val replied = LinkedBlockingQueue<Pair<Int, Bundle>>()
            val reply = object : ResultReceiver(null) {
                override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                    replied.put(resultCode to (resultData ?: Bundle()))
                }
            }
            context.startService(
                Intent(context, CoreService::class.java)
                    .setAction(CoreService.ACTION_APPEND)
                    .putExtra(CoreService.EXTRA_EVENT, event)
                    .putExtra(CoreService.EXTRA_REPLY, reply),
            )
            replied
        }
        return replies.mapIndexed { i, replied ->
            replied.poll(30, TimeUnit.SECONDS) ?: throw AssertionError("the core host never answered append ${i + 1}")
        }
    }

    /**
     * How many events with [ulid] the log itself holds, read from the core's own file
     * (lib/core_host.dart's coreDbPath) rather than from anything the core says.
     */
    fun eventsInLog(ulid: String): Int =
        SQLiteDatabase.openDatabase(File(context.filesDir, "core.db").path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            db.rawQuery("SELECT count(*) FROM events WHERE ulid = ?", arrayOf(ulid)).use { c ->
                c.moveToFirst()
                c.getInt(0)
            }
        }

    fun await(what: String, timeoutMs: Long = 30_000, check: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            if (check()) return
            SystemClock.sleep(200)
        }
        throw AssertionError("timed out after $timeoutMs ms waiting for $what")
    }

    companion object {
        /** An event's wire form (ADR 001's NewEvent), tagged with [run] so this run finds its own. */
        fun probe(run: String) =
            """{"kind":"probe.core_host","source":"test","payload":{"run":"$run"},"payload_version":1,""" +
                """"person":null,"role":null,"corrects_ulid":null}"""
    }
}
