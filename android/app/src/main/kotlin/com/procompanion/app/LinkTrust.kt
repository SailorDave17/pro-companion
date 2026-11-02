package com.procompanion.app

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process

/**
 * Who may send link events (ADR 004, #33). A caller is trusted only when its UID holds the pinned
 * package AND that package is signed by one of the pinned certificates (SHA-256). Both pins are
 * compiled in (android/app/build.gradle.kts), and with no certificate pinned nothing is trusted.
 *
 * A runtime check, not a signature-level permission: race-timer on a personal phone is signed with
 * Play's key and the companion with the owner's upload key, and a `signature` permission needs one
 * signer on both sides, so it would refuse race-timer with no error anywhere.
 */
object LinkTrust {
    sealed interface Verdict
    data object Trusted : Verdict
    data class Untrusted(val reason: String) : Verdict

    /**
     * [sdk] is a parameter so the refusal below API 28 can be proved on any phone. It is the one
     * call this check depends on, and there is no second, weaker path: race-timer needs API 30
     * itself, so the branch can only ever meet an imposter (owner decision on #33, minSdk stays 24).
     */
    fun check(context: Context, uid: Int, sdk: Int = Build.VERSION.SDK_INT): Verdict {
        val pinnedPackage = context.getString(R.string.link_trusted_package)
        val pinnedCerts = context.getString(R.string.link_trusted_certs)
            .split(',')
            .map { it.trim().replace(":", "").lowercase() }
            .filter { it.isNotEmpty() }
        if (uid == Process.INVALID_UID) return Untrusted("no_caller_identity")
        val pm = context.packageManager
        val packages = pm.getPackagesForUid(uid) ?: return Untrusted("unknown_uid")
        if (pinnedCerts.isEmpty()) return Untrusted("no_certificate_pinned")
        if (pinnedPackage !in packages) return Untrusted("package_not_pinned")
        if (sdk < Build.VERSION_CODES.P) return Untrusted("api_below_28")
        val signed = pinnedCerts.any { pm.hasSigningCertificate(pinnedPackage, hex(it), PackageManager.CERT_INPUT_SHA256) }
        return if (signed) Trusted else Untrusted("certificate_not_pinned")
    }

    private fun hex(s: String): ByteArray = ByteArray(s.length / 2) { i -> s.substring(2 * i, 2 * i + 2).toInt(16).toByte() }
}
