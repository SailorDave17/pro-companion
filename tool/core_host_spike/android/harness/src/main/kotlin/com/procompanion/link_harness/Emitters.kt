package com.procompanion.link_harness

import android.app.BroadcastOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** One of the three candidate mechanisms. [send] answers with the companion's status. */
interface Emitter : AutoCloseable {
    fun send(json: String): String
    override fun close() {}
}

fun emitterFor(context: Context, mech: String): Emitter = when (mech) {
    "broadcast" -> BroadcastEmitter(context)
    "bound" -> BoundEmitter(context)
    "provider" -> ProviderEmitter(context)
    else -> throw IllegalArgumentException("unknown mechanism $mech")
}

/**
 * An explicit-package broadcast to the companion's manifest receiver. Implicit
 * broadcasts no longer reach manifest receivers (Android 8), so the package is set.
 * There is no answer: "sent" means only that the system took it.
 */
class BroadcastEmitter(private val context: Context) : Emitter {
    override fun send(json: String): String {
        val intent = Intent(Link.ACTION_EVENT)
            .setPackage(Link.COMPANION)
            .putExtra(Link.EXTRA_EVENT, json)
            .addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
        if (Build.VERSION.SDK_INT >= 34) {
            // Without this the receiver cannot learn who sent it: getSentFromUid()
            // returns INVALID_UID unless the sender opts in.
            val options = BroadcastOptions.makeBasic().setShareIdentityEnabled(true)
            context.sendBroadcast(intent, null, options.toBundle())
        } else {
            context.sendBroadcast(intent)
        }
        return "sent"
    }
}

/**
 * Binds once for the run, as race-timer would for a sequence, and sends one
 * transaction per event. A lost binding is re-made on the next send.
 */
class BoundEmitter(private val context: Context) : Emitter {
    @Volatile private var binder: IBinder? = null
    @Volatile private var connected = CountDownLatch(1)
    private var bound = false

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            binder = service
            connected.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName) {
            binder = null
        }

        override fun onBindingDied(name: ComponentName) {
            binder = null
            unbind()
        }

        override fun onNullBinding(name: ComponentName) {
            connected.countDown()
        }
    }

    private fun bind(): IBinder? {
        if (!bound) {
            connected = CountDownLatch(1)
            val intent = Intent().setComponent(ComponentName(Link.COMPANION, Link.SERVICE_CLASS))
            bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            if (!bound) return null
        }
        connected.await(10, TimeUnit.SECONDS)
        return binder
    }

    private fun unbind() {
        if (bound) runCatching { context.unbindService(connection) }
        bound = false
    }

    override fun send(json: String): String {
        val b = binder ?: bind() ?: return "error:not_bound"
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(Link.DESCRIPTOR)
            data.writeString(json)
            b.transact(Link.TX_EVENT, data, reply, 0)
            reply.readException()
            return reply.readString() ?: "null"
        } catch (e: android.os.DeadObjectException) {
            binder = null
            unbind()
            throw e
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    override fun close() = unbind()
}

/** `ContentResolver.call` on the companion's provider: synchronous, with an answer. */
class ProviderEmitter(private val context: Context) : Emitter {
    private val uri = Uri.parse("content://${Link.AUTHORITY}")

    override fun send(json: String): String =
        context.contentResolver.call(uri, Link.METHOD_EVENT, json, null)?.getString(Link.KEY_STATUS) ?: "null"
}
