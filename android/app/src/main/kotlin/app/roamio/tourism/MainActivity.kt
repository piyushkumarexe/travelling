package app.roamio.tourism

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Log
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
        const val LAUNCH_CHANNEL = "app.roamio.tourism/app_launch"
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LAUNCH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchApp" -> {
                        val pkg = call.argument<String>("package")
                        if (pkg.isNullOrEmpty()) {
                            result.error("invalid", "package required", null)
                        } else {
                            val intent = packageManager.getLaunchIntentForPackage(pkg)
                            if (intent == null) {
                                result.success(false) // genuinely not installed
                            } else {
                                intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                                try {
                                    startActivity(intent)
                                    result.success(true)
                                } catch (e: Exception) {
                                    result.error("launch_failed", "\${e.javaClass.simpleName}: \${e.message}", null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

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
                            try {
                                // "queued" = handed to the radio (callbacks follow);
                                // "composer" = the device's SMS app was opened with
                                // the message pre-filled (user presses Send) — an
                                // HONEST hand-off used when the OEM security layer
                                // blocks direct SmsManager sends.
                                result.success(queueSmsTracked(ref, destination, body))
                            } catch (e: Exception) {
                                // Never swallow the OS reason — Dart shows it
                                // verbatim so the failure is diagnosable.
                                Log.w("EmergencySms", "tracked SMS send failed: ${e.javaClass.simpleName}: ${e.message}")
                                result.error("send_failed", "${e.javaClass.simpleName}: ${e.message}", null)
                            }
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
                        // Some OEMs return a null ServiceState even WITH
                        // signal — reporting "no_service" then would be a
                        // lie and block a perfectly sendable SMS. Report
                        // unknown and let the actual send decide.
                        null -> "unknown"
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
    private fun queueSmsTracked(ref: String, destination: String, body: String): String {
        // No SmsManager at all is a hard failure — propagate so Dart shows
        // the exact reason instead of pretending the send was queued.
        val sms = smsManager() ?: throw Exception("No SMS manager available")
        // ONE receiver per tracked message: re-registered for THIS ref so a
        // follow-up send (new ref) still receives its own sent/delivery
        // callbacks instead of the previous message's filter.
        statusReceiver?.let { r ->
            try {
                unregisterReceiver(r)
            } catch (_: Exception) {
            }
        }
        statusReceiver = null
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
        // Try EVERY distinct SmsManager variant before giving up: on
        // some OEM builds the subscription-specific instance throws where
        // the base one works (and vice versa).
        val managers = LinkedHashSet<SmsManager>()
        managers.add(sms)
        baseSmsManager()?.let { managers.add(it) }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try {
                @Suppress("DEPRECATION")
                managers.add(SmsManager.getDefault())
            } catch (_: Exception) {
            }
        }
        var lastSecurity: SecurityException? = null
        for (m in managers) {
            try {
                if (sendOn(m, destination, body, sentIntent, deliveryIntent)) {
                    return "queued"
                }
            } catch (e: SecurityException) {
                lastSecurity = e
            }
        }
        // Direct send is blocked by the phone's SECURITY LAYER even with
        // SEND_SMS granted (getGroupIdLevel1 class — known on Xiaomi/MIUI
        // and several Android 14 builds). The default SMS app holds the
        // system's own SMS privileges: hand the FULL message off there,
        // pre-filled, and report it honestly as a "composer" hand-off.
        if (sendViaSmsApp(destination, body)) return "composer"
        throw lastSecurity ?: Exception("All SMS send paths failed")
    }

    /**
     * Opens the device's DEFAULT SMS app with [body] pre-filled for
     * [destination].
     *
     * This is the honest last-resort path when the OEM security layer blocks
     * direct SmsManager sends even though SEND_SMS is granted (the
     * getGroupIdLevel1 SecurityException class). The SMS app itself holds
     * the system's SMS privileges, so the message goes out the moment the
     * traveler taps Send in the SMS app. Returns true only when the app
     * actually opened.
     */
    private fun sendViaSmsApp(destination: String, body: String): Boolean {
        return try {
            val intent =
                Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$destination")).apply {
                    putExtra(Intent.EXTRA_SUBJECT, "YatraWise emergency location")
                    putExtra(Intent.EXTRA_SMSP_BODY, body)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** One honest send attempt — exceptions propagate verbatim. */
    private fun sendOn(
        sms: SmsManager,
        destination: String,
        body: String,
        sentIntent: PendingIntent,
        deliveryIntent: PendingIntent
    ): Boolean {
        val parts = sms.divideMessage(body)
        if (parts.size <= 1) {
            // NO swallow: an exception here is the EXACT technical reason
            // (radio/destination/format) — it propagates to Dart verbatim.
            sms.sendTextMessage(destination, null, body, sentIntent, deliveryIntent)
            return true
        }
        val sent = ArrayList<PendingIntent>(parts.size)
        val delivered = ArrayList<PendingIntent>(parts.size)
        for (i in parts.indices) {
            sent.add(sentIntent)
            delivered.add(deliveryIntent)
        }
        try {
            sms.sendMultipartTextMessage(destination, null, parts, sent, delivered)
            return true
        } catch (e: Exception) {
            // Some OEM radios reject multipart sends outright — one honest
            // retry with a compact single-part message (still the real
            // location), then the ORIGINAL exception propagates.
            val compact = compactEmergencyBody(body)
            sms.sendTextMessage(destination, null, compact, sentIntent, deliveryIntent)
            return true
        }
    }

    /** Keeps EMERGENCY header + map link + coords within one SMS part. */
    private fun compactEmergencyBody(body: String): String {
        val link = Regex("https://[^\\s]+").find(body)?.value ?: ""
        val head = body.substring(0, minOf(body.length, 110)).trim()
        return if (link.isNotEmpty()) "$head\n$link" else head
    }

    /** The DEFAULT (no-subscription) manager — works on every Android version. */
    private fun baseSmsManager(): SmsManager? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }

    /**
     * Preferred manager: the default SMS subscription's (dual-SIM — the radio
     * accepts sends only on that sub). Some OEM/Android-14 builds throw
     * SecurityException (getGroupIdLevel1) on the subscription-specific send
     * even with SEND_SMS granted — the callers therefore fall back to
     * [baseSmsManager] when a SecurityException comes out of this one.
     */
    private fun smsManager(): SmsManager? {
        val base = baseSmsManager() ?: return null
        val subId = android.telephony.SubscriptionManager
            .getDefaultSmsSubscriptionId()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            subId != android.telephony.SubscriptionManager.INVALID_SUBSCRIPTION_ID
        ) {
            return try {
                SmsManager.getSmsManagerForSubscriptionId(subId)
            } catch (_: Exception) {
                base
            }
        }
        return base
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

    /** Queues the message with the radio. True when handed off successfully
     *  — either to the radio directly or (when the OEM security layer blocks
     *  direct sends) to the default SMS app with the message pre-filled.
     *  Handles the Xiaomi/Android-14 SecurityException(getGroupIdLevel1) by
     *  falling back across SmsManager variants, then to the SMS app. */
    private fun queueSms(destination: String, body: String): Boolean {
        val sms: SmsManager? = smsManager()
        if (sms == null) return false
        return try {
            val parts = sms.divideMessage(body)
            if (parts.size <= 1) {
                sms.sendTextMessage(destination, null, body, null, null)
            } else {
                sms.sendMultipartTextMessage(destination, null, parts, null, null)
            }
            true
        } catch (e: SecurityException) {
            // Subscription-specific manager blocked by OEM security layer.
            val base = baseSmsManager()
            if (base != null && base !== sms) {
                try {
                    val parts = base.divideMessage(body)
                    if (parts.size <= 1) {
                        base.sendTextMessage(destination, null, body, null, null)
                    } else {
                        base.sendMultipartTextMessage(destination, null, parts, null, null)
                    }
                    return true
                } catch (_: Exception) {
                    // Fall through to the SMS-app hand-off.
                }
            }
            // Honest last resort: the default SMS app holds the system's
            // own SMS privileges (see sendViaSmsApp).
            return sendViaSmsApp(destination, body)
        } catch (_: Exception) {
            false
        }
    }
}
