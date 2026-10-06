package com.procompanion.core_host_spike

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process

/**
 * #15: who may send link events. A caller is trusted only when its UID holds the
 * pinned package AND that package is signed by one of the pinned certificates
 * (SHA-256). Both pins are build inputs (`-PlinkTrustedPackage`, `-PlinkTrustedCerts`),
 * and with no certificate pinned nothing is trusted.
 *
 * This is a runtime check, not a signature-level permission: race-timer reaches the
 * club phone through Play, signed with Play's app-signing key, while the companion is
 * sideloaded with the owner's upload key (groom decision G20). A `signature` permission
 * needs one signer on both sides, so it would refuse race-timer without any error.
 */
object LinkTrust {
    sealed interface Verdict
    data class Trusted(val pkg: String) : Verdict
    data class Untrusted(val reason: String, val packages: List<String>) : Verdict

    fun check(context: Context, uid: Int): Verdict {
        val pinnedPackage = context.getString(R.string.link_trusted_package)
        val pinnedCerts = context.getString(R.string.link_trusted_certs)
            .split(',')
            .map { it.trim().replace(":", "").lowercase() }
            .filter { it.isNotEmpty() }
        if (uid == Process.INVALID_UID) return Untrusted("no_caller_identity", emptyList())
        val pm = context.packageManager
        val packages = pm.getPackagesForUid(uid)?.toList() ?: return Untrusted("unknown_uid", emptyList())
        if (pinnedCerts.isEmpty()) return Untrusted("no_certificate_pinned", packages)
        if (pinnedPackage !in packages) return Untrusted("package_not_pinned", packages)
        // hasSigningCertificate is API 28, below the app's minSdk (24). The spike refuses
        // there rather than crash; ADR 004 leaves the older-phone path to #33.
        if (Build.VERSION.SDK_INT < 28) return Untrusted("api_below_28", packages)
        val signed = pinnedCerts.any { pm.hasSigningCertificate(pinnedPackage, hex(it), PackageManager.CERT_INPUT_SHA256) }
        return if (signed) Trusted(pinnedPackage) else Untrusted("certificate_not_pinned", packages)
    }

    private fun hex(s: String): ByteArray = ByteArray(s.length / 2) { i -> s.substring(2 * i, 2 * i + 2).toInt(16).toByte() }
}
