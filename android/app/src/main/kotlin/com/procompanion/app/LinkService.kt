package com.procompanion.app

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel

/**
 * The race-timer link (ADR 004, #33): race-timer binds this and sends each event as one raw binder
 * transaction, answered with a [LinkContract] status. The app's only exported component beside its
 * launcher activity, so the receipt time comes first, then the caller, and the payload is read last
 * ([LinkInbox]). The caller's UID is the one the platform vouches for, never one the payload names.
 *
 * It deliberately neither starts nor binds [CoreService]. A bind would run the core's engine with no
 * foreground service behind it, and a background start of a `location` service is refused, so with
 * the host down it answers `no_core`, and the host stays down until the PRO opens the app (ADR 004).
 */
class LinkService : Service() {
    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != LinkContract.TX_EVENT) return super.onTransact(code, data, reply, flags)
            val receivedMs = System.currentTimeMillis()
            val uid = getCallingUid()
            val status = LinkInbox.receive(this@LinkService, uid, receivedMs) {
                data.enforceInterface(LinkContract.DESCRIPTOR)
                data.readString()
            }
            reply?.writeNoException()
            reply?.writeString(status)
            return true
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder
}
