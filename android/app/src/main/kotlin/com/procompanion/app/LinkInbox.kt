package com.procompanion.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Where a link event lands (ADR 004, #33): the caller is judged before its payload is read, and the
 * answer is the core's. Only the binder thread running the call waits, never the main thread.
 *
 * `accepted` means the core committed the event, so a call that outlives [WAIT_MS] answers
 * `no_core` and stays queued. If it does commit later, race-timer's retry under the same id is
 * accepted and stores nothing. It must never answer `accepted`, which would claim a store that
 * may not happen, nor `refused`, which race-timer does not resend. 2 s is far above the 41 ms the
 * slowest event took on a phone (ADR 004, "On the club phone"), and matches connectCore's ping.
 */
object LinkInbox {
    const val WAIT_MS = 2_000L
    private const val TAG = "LINK"
    private val main = Handler(Looper.getMainLooper())

    /** The whole of one transaction. [readEvent] is called only once the caller is trusted. */
    fun receive(context: Context, uid: Int, receivedMs: Long, readEvent: () -> String?): String {
        when (val verdict = LinkTrust.check(context, uid)) {
            is LinkTrust.Untrusted -> {
                LinkRefusals.record(context, receivedMs, uid, verdict.reason)
                return LinkContract.REFUSED
            }
            LinkTrust.Trusted -> Unit
        }
        val event = readEvent() ?: return LinkContract.MALFORMED
        return deliver(event, receivedMs)
    }

    /**
     * Past the trust check: hands [event] to the core and waits for its answer. A test in the app's
     * own process reaches the host's states here, since the trust check refuses that process.
     */
    fun deliver(event: String, receivedMs: Long, waitMs: Long = WAIT_MS): String {
        if (CoreService.live == null) return LinkContract.NO_CORE
        val answer = CompletableFuture<String>()
        main.post {
            // Again, on the main thread: the host may have gone since the check above.
            val host = CoreService.live
            if (host == null) answer.complete(LinkContract.NO_CORE) else host.link(event, receivedMs, answer)
        }
        return try {
            answer.get(waitMs, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            Log.w(TAG, "no answer in $waitMs ms: told no_core, and the event stays queued")
            LinkContract.NO_CORE
        } catch (e: ExecutionException) {
            Log.w(TAG, "the core failed: $e")
            LinkContract.NO_CORE
        }
    }
}

/**
 * A refusal, for whoever reads the phone later (ADR 004 decision 2): only the time, the caller's UID
 * and the reason, never the payload, which was not read, and never the package names, which on a
 * personal phone would say what else is installed. In noBackupFilesDir and bounded, because any app
 * can call an exported service: two files of [MAX_BYTES], the older dropped.
 */
object LinkRefusals {
    const val FILE = "link_refusals.log"
    private const val MAX_BYTES = 16 * 1024L

    fun record(context: Context, atMs: Long, uid: Int, reason: String) {
        val line = "$atMs uid=$uid reason=$reason"
        Log.w("LINK", "REFUSED $line")
        try {
            synchronized(this) {
                val file = File(context.noBackupFilesDir, FILE)
                if (file.length() >= MAX_BYTES) file.renameTo(File(context.noBackupFilesDir, "$FILE.1"))
                file.appendText("$line\n")
            }
        } catch (e: java.io.IOException) {
            // The refusal stands whether or not it could be written down.
            Log.w("LINK", "could not record a refusal: $e")
        }
    }
}
