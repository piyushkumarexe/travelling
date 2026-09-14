package app.roamio.tourism

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
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
        const val STATUS_CHANNEL = "app.roamio.tourism/emergency_sms_status"
        const val REQ_SEND_SMS = 4711
    }

    /** Pending MethodChannel result for the in-flight permission request. */
    private var pendingSmsPermissionResult: MethodChannel.Result? = null

    /** Live SMS status events forwarded to Dart (sent / delivery / failure). */
    private var statusSink: EventChannel.EventSink? = null

    private var statusReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // SMS lifecycle events -> Dart. ONE sticky state per message ref;
        // Dart decides what is shown to the user. Android is the only source
        // of truth here — the app never reports "sent" unless the radio
        // acknowledged it (RESULT_ERROR_* reports the failure honestly).
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STATUS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    statusSink = events
                }

                override fun onCancel(args: Any?) {
                    statusSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasSendSms" -> result.success(hasSendSms())
                    "simState" -> result.success(simState())
                    "cellularState" -> result.success(cellularState())
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
                    "sendSmsTracked" -> {
                        val destination = call.argument<String>("to")
                        val body = call.argument<String>("text")
                        val ref = call.argument<String>("ref")
                        if (destination.isNullOrEmpty() || body.isNullOrEmpty() || ref.isNullOrEmpty()) {
                            result.error("invalid", "to/text/ref required", null)
                        } else if (!hasSendSms()) {
                            result.error("permission", "SEND_SMS not granted", null)
                        } else {
                            result.success(queueSmsTracked(ref, destination, body))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        statusReceiver?.let { r ->
            try {
                unregisterReceiver(r)
            } catch (_: Exception) {
            }
        }
        statusReceiver = null
        super.onDestroy()
    }

    // ---- honest SIM / cellular capability reporting -------------------------

    /** "ready" | "no_sim" | "unknown" — from TelephonyManager's SIM state. */
    private fun simState(): String {
        val tm = getSystemService(TelephonyManager::class.java) ?: return "unknown"
        return try {
            when (tm.simState) {
                TelephonyManager.SIM_STATE_READY -> "ready"
                TelephonyManager.SIM_STATE_ABSENT -> "no_sim"
                else -> "unknown"
            }
        } catch (_: Exception) {
            "unknown"
        }
    }

    /** "service" | "no_service" | "emergency_only" | "unknown". */
    private fun cellularState(): String {
        val tm = getSystemService(TelephonyManager::class.java) ?: return "unknown"
        return try {
            when (tm.simState) {
                TelephonyManager.SIM_STATE_READY -> {
                    when (tm.serviceState?.state) {
                        android.telephony.ServiceState.STATE_IN_SERVICE -> "service"
                        android.telephony.ServiceState.STATE_EMERGENCY_ONLY -> "emergency_only"
                        else -> "no_service"
                    }
                }
                TelephonyManager.SIM_STATE_ABSENT -> "no_sim"
                else -> "unknown"
            }
        } catch (_: Exception) {
            "unknown"
        }
    }

    // ---- tracked send with SENT / DELIVERY callbacks -------------------------
    //
    // Android reports radio acceptance through the sent PendingIntent and
    // (carrier permitting) delivery through the delivery PendingIntent. Both
    // are forwarded to Dart as {ref, kind, ok, error}. Nothing is invented:
    // until a callback arrives the state is simply "pending".

    @SuppressLint("UnsafeProtectedBroadcastReceiver")
    private fun queueSmsTracked(ref: String, destination: String, body: String): Boolean {
        val sms = smsManager() ?: return false
        if (statusReceiver == null) {
            val filter = IntentFilter().apply {
                addAction("$ref.sent")
                addAction("$ref.delivered")
            }
            statusReceiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    val action = intent?.action ?: return
                    val r = action.removeSuffix(".sent").removeSuffix(".delivered")
                    val kind = if (action.endsWith(".sent")) "sent" else "delivery"
                    val ok = resultCode == android.app.Activity.RESULT_OK
                    val err = when (resultCode) {
                        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "generic_failure"
                        SmsManager.RESULT_ERROR_NO_SERVICE -> "no_service"
                        SmsManager.RESULT_ERROR_NULL_PDU -> "null_pdu"
                        SmsManager.RESULT_ERROR_RADIO_OFF -> "radio_off"
                        else -> null
                    }
                    statusSink?.success(
                        mapOf(
                            "ref" to r,
                            "kind" to kind,
                            "ok" to ok,
                            "error" to err
                        )
                    )
                }
            }
            ContextCompat.registerReceiver(
                this, statusReceiver!!, filter, ContextCompat.RECEIVER_EXPORTED
            )
        }

        val sentIntent = PendingIntent.getBroadcast(
            this, ref.hashCode(),
            Intent("$ref.sent").setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val deliveryIntent = PendingIntent.getBroadcast(
            this, ref.hashCode() + 1,
            Intent("$ref.delivered").setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return try {
            val parts = sms.divideMessage(body)
            if (parts.size <= 1) {
                sms.sendTextMessage(destination, null, body, sentIntent, deliveryIntent)
            } else {
                val sent = ArrayList<PendingIntent>(parts.size)
                val delivered = ArrayList<PendingIntent>(parts.size)
                for (i in parts.indices) {
                    sent.add(sentIntent)
                    delivered.add(deliveryIntent)
                }
                sms.sendMultipartTextMessage(destination, null, parts, sent, delivered)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun smsManager(): SmsManager? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
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
        val sms: SmsManager? = smsManager()
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
