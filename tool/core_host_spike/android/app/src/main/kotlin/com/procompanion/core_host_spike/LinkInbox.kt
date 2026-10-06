package com.procompanion.core_host_spike

import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.time.Instant

/**
 * #15: where all three mechanisms land. It judges the caller before reading the
 * payload, then hands the event to the headless core (CoreService), which writes
 * it as a `LINK` line. A refusal is written to `link_reject.log`, never to the core.
 */
object LinkInbox {
    const val TAG = "LINK"
    const val REJECT_LOG = "link_reject.log"

    fun receive(context: Context, mech: String, callerUid: Int, json: String?, recvNs: Long): String {
        when (val verdict = LinkTrust.check(context, callerUid)) {
            is LinkTrust.Untrusted -> {
                val line = "REJECT mech=$mech uid=$callerUid reason=${verdict.reason} packages=${verdict.packages.joinToString("|")}"
                Log.w(TAG, line)
                File(context.filesDir, REJECT_LOG).appendText("${Instant.now()} $line\n")
                return LinkContract.REFUSED
            }
            is LinkTrust.Trusted -> Unit
        }
        val event = runCatching { JSONObject(json!!) }.getOrNull()
        val id = event?.optString("id").orEmpty()
        if (event == null || id.isEmpty()) {
            Log.w(TAG, "MALFORMED mech=$mech uid=$callerUid")
            return LinkContract.MALFORMED
        }
        // x_ fields are the harness's own. The hop is measured on elapsedRealtime, the
        // one clock both processes share exactly.
        val emitNs = event.optLong("x_emit_ns", -1)
        val hopUs = if (emitNs > 0) (recvNs - emitNs) / 1000 else -1
        Log.i(TAG, "RECV run=${event.optString("x_run", "-")} mech=$mech n=${event.optInt("x_n", -1)} id=$id hop_us=$hopUs")
        val forward = JSONObject()
            .put("mech", mech)
            .put("recv_ns", recvNs)
            .put("handed_ns", SystemClock.elapsedRealtimeNanos())
            .put("event", event)
        return if (CoreService.deliver("$LINK_PREFIX$forward")) LinkContract.ACCEPTED else LinkContract.NO_CORE
    }

    /** The payload prefix `coreMain` routes to its link handler. */
    const val LINK_PREFIX = "link:"
}
