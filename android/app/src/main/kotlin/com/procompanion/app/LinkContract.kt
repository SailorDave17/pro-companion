package com.procompanion.app

import android.os.IBinder

/**
 * The companion's half of the race-timer link's transport (ADR 004, #33). What an event must hold
 * is judged in one place, packages/core/lib/src/link.dart, so nothing here reads one.
 */
object LinkContract {
    const val DESCRIPTOR = "com.procompanion.link.ILink"
    const val TX_EVENT = IBinder.FIRST_CALL_TRANSACTION

    /** The core has committed the event, or held it already. */
    const val ACCEPTED = "accepted"

    /** The caller is not the pinned package signed by a pinned certificate. race-timer does not resend. */
    const val REFUSED = "refused"

    /** The core could not read it as an event. race-timer does not resend. */
    const val MALFORMED = "malformed"

    /** Nothing committed it, so race-timer keeps the event and resends it under the same id. */
    const val NO_CORE = "no_core"
}
