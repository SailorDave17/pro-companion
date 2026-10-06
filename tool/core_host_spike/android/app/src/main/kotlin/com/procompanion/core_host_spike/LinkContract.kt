package com.procompanion.core_host_spike

import android.os.IBinder

/**
 * #15: the companion's half of the race-timer link contract (pro-companion ADR 004).
 * The harness carries the same names in its `Contract.kt`, as race-timer would.
 */
object LinkContract {
    const val ACTION_EVENT = "com.procompanion.link.EVENT"
    const val EXTRA_EVENT = "event"
    const val DESCRIPTOR = "com.procompanion.link.ILink"
    const val TX_EVENT = IBinder.FIRST_CALL_TRANSACTION
    const val METHOD_EVENT = "event"
    const val KEY_STATUS = "status"

    /** Handed to the core. */
    const val ACCEPTED = "accepted"

    /** The caller is not the pinned package signed by a pinned certificate. */
    const val REFUSED = "refused"

    /** Not a JSON object with a string `id`. */
    const val MALFORMED = "malformed"

    /** The core host is not running, so nothing could take the event. */
    const val NO_CORE = "no_core"
}
