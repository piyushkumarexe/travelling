package app.roamio.tourism

import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.roamio.tourism/signing",
        ).setMethodCallHandler { call, result ->
            if (call.method == "fingerprints") {
                result.success(signingFingerprints())
            } else {
                result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun signingFingerprints(): String {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            ).signingInfo
            if (info.hasMultipleSigners()) {
                info.apkContentsSigners
            } else {
                info.signingCertificateHistory
            }
        } else {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNATURES,
            ).signatures
        }

        val certificate = signatures.first().toByteArray()
        return "SHA-1: ${digest(certificate, "SHA-1")}\n" +
            "SHA-256: ${digest(certificate, "SHA-256")}"
    }

    private fun digest(certificate: ByteArray, algorithm: String): String =
        MessageDigest.getInstance(algorithm)
            .digest(certificate)
            .joinToString(":") { byte -> "%02X".format(byte) }
}
