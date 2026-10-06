package com.procompanion.core_host_spike

import android.app.Service
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import android.os.SystemClock

/*
 * #15: the three candidate mechanisms for the race-timer link, each a thin entry
 * point into LinkInbox. Each stamps its receipt time first and names its caller's
 * UID from what the platform vouches for, never from the payload.
 */

/**
 * Broadcast. Its caller is known only when the sender opted in to sharing its
 * identity (Android 14+); otherwise getSentFromUid() is INVALID_UID and LinkTrust
 * refuses it. A broadcast has no answer, so the sender never learns of a refusal.
 */
class LinkReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val recvNs = SystemClock.elapsedRealtimeNanos()
        val uid = if (Build.VERSION.SDK_INT >= 34) sentFromUid else Process.INVALID_UID
        LinkInbox.receive(context, "broadcast", uid, intent.getStringExtra(LinkContract.EXTRA_EVENT), recvNs)
    }
}

/** Bound service: one transaction per event, answered with a LinkContract status. */
class LinkService : Service() {
    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != LinkContract.TX_EVENT) return super.onTransact(code, data, reply, flags)
            val recvNs = SystemClock.elapsedRealtimeNanos()
            data.enforceInterface(LinkContract.DESCRIPTOR)
            val status = LinkInbox.receive(this@LinkService, "bound", Binder.getCallingUid(), data.readString(), recvNs)
            reply?.writeNoException()
            reply?.writeString(status)
            return true
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder
}

/** Content provider: `call(…, "event", json)` answers with a Bundle carrying the status. */
class LinkProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        if (method != LinkContract.METHOD_EVENT) return null
        val recvNs = SystemClock.elapsedRealtimeNanos()
        val status = LinkInbox.receive(context!!, "provider", Binder.getCallingUid(), arg, recvNs)
        return Bundle().apply { putString(LinkContract.KEY_STATUS, status) }
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
