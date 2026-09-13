package app.roamio.tourism

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity with a small emergency-SMS channel.
 *
 * The Dart side (SmsService) uses this to:
 *   - check/request the SEND_SMS runtime permission (SOS + Power-Off Safety
 *     Location need it so the SOS contact receives the traveler's location
 *     and coordinates even when mobile data is off), and
 *   - queue an SMS directly via SmsManager (used by SOS and live location
 *     sharing).
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "app.roamio.tourism/emergency_sms"
        const val REQ_SEND_SMS = 4711
    }

    /** Pending MethodChannel result for the in-flight permission request. */
    private var pendingSmsPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasSendSms" -> result.success(hasSendSms())
                    "requestSendSms" -> {
                        if (hasSendSms()) {
                            result.success(true)
                        } else if (pendingSmsPermissionResult != null) {
                            result.error("busy", "A permission request is already showing", null)
                        } else {
                            // Hold the channel result until the user answers
                            // the system dialog, so Dart gets the REAL grant
                            // decision instead of a premature false.
                            pendingSmsPermissionResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.SEND_SMS),
                                REQ_SEND_SMS,
                            )
                        }
                    }
                    "sendSms" -> {
                        val destination = call.argument<String>("to")
                        val body = call.argument<String>("text")
                        if (destination.isNullOrEmpty() || body.isNullOrEmpty()) {
                            result.error("invalid", "to/text required", null)
                        } else if (!hasSendSms()) {
                            result.error("permission", "SEND_SMS not granted", null)
                        } else {
                            result.success(queueSms(destination, body))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_SEND_SMS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingSmsPermissionResult?.let { r ->
                try {
                    r.success(granted)
                } catch (_: Exception) {
                    // Engine detached before the answer arrived — nothing to do.
                }
            }
            pendingSmsPermissionResult = null
        }
    }

    private fun hasSendSms(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) ==
            PackageManager.PERMISSION_GRANTED

    /** Queues the message with the radio. True when handed off successfully. */
    private fun queueSms(destination: String, body: String): Boolean {
        val sms: SmsManager? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        if (sms == null) return false
        val parts = sms.divideMessage(body)
        return try {
            if (parts.size <= 1) {
                sms.sendTextMessage(destination, null, body, null, null)
            } else {
                sms.sendMultipartTextMessage(destination, null, parts, null, null)
            }
            true
        } catch (_: Exception) {
            false
        }
    }
}
