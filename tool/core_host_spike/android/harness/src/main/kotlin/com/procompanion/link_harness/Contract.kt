package com.procompanion.link_harness

import android.os.IBinder
import org.json.JSONObject
import java.util.UUID

/**
 * The race-timer link contract (pro-companion ADR 004), copied here the way race-timer
 * would copy it. The names point at the core host spike, which stands in for the
 * companion; the ADR gives the production names. The companion's copy is
 * `LinkContract.kt` in the spike app.
 */
object Link {
    const val COMPANION = "com.procompanion.core_host_spike"

    /** Broadcast: an explicit-package broadcast to a manifest receiver. */
    const val ACTION_EVENT = "com.procompanion.link.EVENT"
    const val EXTRA_EVENT = "event"

    /** Bound service: one transaction per event, answered with a status string. */
    const val SERVICE_CLASS = "com.procompanion.core_host_spike.LinkService"
    const val DESCRIPTOR = "com.procompanion.link.ILink"
    const val TX_EVENT = IBinder.FIRST_CALL_TRANSACTION

    /** Content provider: `call(content://AUTHORITY, METHOD_EVENT, json)`. */
    const val AUTHORITY = "com.procompanion.core_host_spike.link"
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

class Emission(val id: String, val kind: String, val json: String)

/** Builds the run's events. Fields prefixed `x_` are the harness's own, not the contract's. */
class EventScript(private val run: String) {
    private var sequence: String? = null

    fun event(n: Int, emitNs: Long): Emission {
        val step = DAY[(n - 1) % DAY.size]
        val id = UUID.randomUUID().toString()
        if (step.kind == "sequence_start") sequence = id
        val e = JSONObject()
            .put("v", Link.VERSION)
            .put("id", id)
            .put("kind", step.kind)
            .put("at_ms", System.currentTimeMillis())
            .put("sequence", sequence ?: id)
        if (step.kind == "sequence_start") e.put("sequence_name", "5-4-1-0")
        if (step.signal != null) e.put("signal", step.signal).put("seconds_to_start", step.secondsToStart)
        e.put("x_run", run).put("x_n", n).put("x_emit_ns", emitNs)
        return Emission(id, step.kind, e.toString())
    }
}
