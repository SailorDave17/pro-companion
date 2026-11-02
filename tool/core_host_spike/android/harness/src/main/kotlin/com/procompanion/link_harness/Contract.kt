package com.procompanion.link_harness

import android.os.IBinder
import org.json.JSONObject
import java.util.UUID

/**
 * The race-timer link contract (pro-companion ADR 004), copied here the way race-timer
 * would copy it. The companion defaults to the core host spike, which stands in for
 * it; a run names another with `--es companion` (#33, the real app). The ADR gives the
 * production names. The companion's copy is `LinkContract.kt` in the spike app.
 */
object Link {
    const val COMPANION = "com.procompanion.core_host_spike"

    /** Broadcast: an explicit-package broadcast to a manifest receiver. */
    const val ACTION_EVENT = "com.procompanion.link.EVENT"
    const val EXTRA_EVENT = "event"

    /** Bound service: one transaction per event, answered with a status string. */
    fun serviceClass(companion: String) = "$companion.LinkService"
    const val DESCRIPTOR = "com.procompanion.link.ILink"
    const val TX_EVENT = IBinder.FIRST_CALL_TRANSACTION

    /** Content provider: `call(content://authority, METHOD_EVENT, json)`. */
    fun authority(companion: String) = "$companion.link"
    const val METHOD_EVENT = "event"
    const val KEY_STATUS = "status"

    const val VERSION = 1
}

/** One scripted step: the contract kind, and a signal's name and seconds to the start. */
private data class Step(
    val kind: String,
    val signal: String? = null,
    val secondsToStart: Int? = null,
)

/**
 * A plausible stretch of a race day, cycled until the run's count is reached, so
 * that 50 events carry every contract kind: a start with an individual recall, a
 * sequence postponed after its warning, and a start that is generally recalled.
 */
private val DAY = listOf(
    Step("sequence_start"),
    Step("signal", "warning", 300),
    Step("signal", "preparatory", 240),
    Step("signal", "one_minute", 60),
    Step("start"),
    Step("individual_recall"),
    Step("sequence_start"),
    Step("signal", "warning", 300),
    Step("postponement"),
    Step("sequence_start"),
    Step("signal", "warning", 300),
    Step("signal", "preparatory", 240),
    Step("signal", "one_minute", 60),
    Step("start"),
    Step("general_recall"),
)

class Emission(val id: String, val kind: String, val atMs: Long, val json: String)

/** Builds the run's events. Fields prefixed `x_` are the harness's own, not the contract's. */
class EventScript(private val run: String) {
    private var sequence: String? = null

    fun event(n: Int, emitNs: Long): Emission {
        val step = DAY[(n - 1) % DAY.size]
        val id = UUID.randomUUID().toString()
        val atMs = System.currentTimeMillis()
        if (step.kind == "sequence_start") sequence = id
        val e = JSONObject()
            .put("v", Link.VERSION)
            .put("id", id)
            .put("kind", step.kind)
            .put("at_ms", atMs)
            .put("sequence", sequence ?: id)
        if (step.kind == "sequence_start") e.put("sequence_name", "5-4-1-0")
        if (step.signal != null) e.put("signal", step.signal).put("seconds_to_start", step.secondsToStart)
        // A string, because elapsed nanoseconds pass 2^53 after about 104 days of uptime. The
        // real app's core stores unknown fields and refuses an integer past that as malformed
        // (#33). The spike's reader, LinkInbox.kt, takes it through optLong either way.
        e.put("x_run", run).put("x_n", n).put("x_emit_ns", emitNs.toString())
        return Emission(id, step.kind, atMs, e.toString())
    }
}
