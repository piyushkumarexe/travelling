package app.roamio.tourism

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.concurrent.thread

/**
 * Power-Off Safety Location (best-effort, fail-safe).
 *
 * When Android broadcasts [Intent.ACTION_SHUTDOWN], this receiver makes ONE
 * fast, best-effort attempt to tell the configured SOS contact where the
 * traveler was, using TWO independent channels in priority order:
 *
 *  1. **SMS (primary)** — works on the cellular network even when mobile
 *     data is off or the internet is already being torn down, which is
 *     exactly the situation during shutdown. Fire-and-forget via SmsManager
 *     (no delivery confirmation is possible in the shutdown window).
 *  2. **Firestore (secondary)** — the same emergency event the app's SOS
 *     flow uses, via the Firestore REST API (visible to admins in-app).
 *
 * Hard technical limits (documented honestly in the app):
 *  - It can only reuse the LATEST AVAILABLE location. It never claims to
 *    obtain a new GPS fix after the phone is off — that is impossible.
 *  - The shutdown window is short; SMS is queued to the radio as fast as
 *    possible so it has the best chance of going out before power is cut.
 *  - WhatsApp cannot be used here: it requires launching the app and a live
 *    data connection, both impossible during shutdown. SMS is the honest
 *    channel for this moment.
 *
 * Required permissions: SEND_SMS must be granted at runtime from the app
 * (Safety screen prompts for it when Power-Off Safety Location is enabled).
 * Without it, this receiver silently skips SMS and only tries Firestore.
 */
class PowerOffReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "PowerOffReceiver"
        private const val PREFS = "FlutterSharedPreferences"
        private const val K_ENABLED = "flutter.power_off_safety.enabled"
        private const val K_PHONE = "flutter.power_off_safety.sos_phone"
        private const val K_NAME = "flutter.power_off_safety.sos_name"
        private const val K_PROJECT = "flutter.power_off_safety.project_id"
        private const val K_TOKEN = "flutter.power_off_safety.id_token"
        private const val K_LAST_POS = "flutter.last_known_position"
        private const val K_EVENT = "flutter.power_off_safety.last_event"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_SHUTDOWN &&
            intent.action != "android.intent.action.QUICKBOOT_POWEROFF"
        ) {
            return
        }
        // goAsync is not usable reliably here; do the work on a worker thread
        // with a hard time bound so the receiver returns quickly either way.
        val pending = goAsync()
        thread(name = "power-off-safety") {
            try {
                handleShutdown(context)
            } catch (t: Throwable) {
                Log.w(TAG, "power-off attempt failed", t)
            } finally {
                pending.finish()
            }
        }
    }

    private fun handleShutdown(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean(K_ENABLED, false)
        if (!enabled) return

        val event = JSONObject()
        event.put("enabled", true)
        event.put("timestamp", System.currentTimeMillis())

        val loc = readLocation(prefs)
        if (loc == null) {
            event.put("sendAttempted", false)
            event.put("sendConfirmed", false)
            event.put("note", "No cached location available.")
            writeEvent(prefs, event)
            return
        }
        val lat = loc.first
        val lng = loc.second
        val fixAgeMs = loc.third?.let { System.currentTimeMillis() - it }
        event.put("latitude", lat)
        event.put("longitude", lng)
        event.put("mapLink", "https://www.google.com/maps?q=$lat,$lng")

        val phone = prefs.getString(K_PHONE, null).orEmpty()
        if (phone.isEmpty()) {
            event.put("sendAttempted", false)
            event.put("sendConfirmed", false)
            event.put("note", "No SOS contact configured.")
            writeEvent(prefs, event)
            return
        }

        // ---- Channel 1: SMS (primary — no data connection required) ----
        val smsQueued = try {
            sendEmergencySms(
                context = context,
                phone = phone,
                name = prefs.getString(K_NAME, null).orEmpty(),
                lat = lat,
                lng = lng,
                fixAgeMs = fixAgeMs
            )
        } catch (t: Throwable) {
            Log.w(TAG, "power-off SMS failed", t)
            false
        }
        event.put("smsQueued", smsQueued)

        // ---- Channel 2: Firestore event (secondary) ----
        val confirmed = postEmergencyEvent(
            prefs.getString(K_PROJECT, null),
            prefs.getString(K_TOKEN, null),
            prefs.getString(K_NAME, null).orEmpty(),
            phone,
            lat,
            lng
        )
        event.put("sendAttempted", true)
        event.put("sendConfirmed", confirmed)
        event.put(
            "note",
            when {
                smsQueued && confirmed -> "SMS queued and cloud event written."
                smsQueued -> "SMS queued (cloud write unconfirmed)."
                confirmed -> "Cloud event written (SMS unavailable)."
                else -> "Send could not be confirmed."
            }
        )
        writeEvent(prefs, event)
    }

    /**
     * Builds the emergency text and queues it with SmsManager. Returns true
     * when the message was handed to the radio (delivery is best-effort by
     * nature of the shutdown window).
     */
    private fun sendEmergencySms(
        context: Context,
        phone: String,
        name: String,
        lat: Double,
        lng: Double,
        fixAgeMs: Long?
    ): Boolean {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "SEND_SMS not granted — skipping power-off SMS")
            return false
        }
        val text = buildMessage(
            name = name.ifEmpty { "Traveler" },
            lat = lat,
            lng = lng,
            fixAgeMs = fixAgeMs
        )
        val sms = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        } ?: return false

        // Fire-and-forget: no sent-intents — every millisecond counts here and
        // the PendingIntent would not be delivered anyway before power-off.
        val parts = sms.divideMessage(text)
        if (parts.size <= 1) {
            sms.sendTextMessage(phone, null, text, null, null)
        } else {
            sms.sendMultipartTextMessage(phone, null, parts, null, null)
        }
        Log.i(TAG, "power-off SMS handed to radio ($phone)")
        return true
    }

    private fun buildMessage(name: String, lat: Double, lng: Double, fixAgeMs: Long?): String {
        val sb = StringBuilder()
        sb.append("EMERGENCY (Tourism): ").append(name)
            .append("'s phone is switching OFF now. Last known location: ")
            .append(lat).append(",").append(lng)
            .append(" https://maps.google.com/?q=").append(lat).append(",").append(lng)
        if (fixAgeMs != null && fixAgeMs >= 0) {
            val ageMin = fixAgeMs / 60000L
            sb.append(" (location ")
            when {
                ageMin < 1 -> sb.append("less than a minute")
                ageMin < 120 -> sb.append(ageMin).append(" min")
                ageMin < 2880 -> sb.append(ageMin / 60L).append(" hours")
                else -> sb.append(ageMin / 1440L).append(" days")
            }
            sb.append(" old)")
        }
        val time = SimpleDateFormat("d MMM yyyy, h:mm a", Locale.US).format(Date())
        sb.append(" · sent ").append(time)
        return sb.toString()
    }

    private fun readLocation(prefs: android.content.SharedPreferences): Triple<Double, Double, Long?>? {
        val raw = prefs.getString(K_LAST_POS, null) ?: return null
        return try {
            val json = JSONObject(raw)
            val lat = json.optDouble("latitude")
            val lng = json.optDouble("longitude")
            if (lat.isNaN() || lng.isNaN() || lat == 0.0 && lng == 0.0) null
            else Triple(lat, lng, if (json.has("timestamp")) json.optLong("timestamp") else null)
        } catch (t: Throwable) {
            Log.w(TAG, "could not parse cached location", t)
            null
        }
    }

    /** Returns true ONLY when Firestore acknowledged the write (HTTP 2xx). */
    private fun postEmergencyEvent(
        projectId: String?,
        idToken: String?,
        name: String,
        phone: String,
        lat: Double,
        lng: Double
    ): Boolean {
        if (projectId.isNullOrEmpty() || idToken.isNullOrEmpty()) return false
        return try {
            val body = JSONObject()
                .put("fields", JSONObject()
                    .put("uid", stringValue("power_off_$phone"))
                    .put("name", stringValue(name.ifEmpty { "Traveler" }))
                    .put("status", stringValue("power_off"))
                    .put("note", stringValue("Power-off safety location (best-effort during shutdown)"))
                    .put("location", JSONObject()
                        .put("mapValue", JSONObject()
                            .put("fields", JSONObject()
                                .put("lat", doubleValue(lat))
                                .put("lng", doubleValue(lng)))))
                    .put("createdAt", JSONObject()
                        .put("timestampValue", rfc3339(System.currentTimeMillis()))))

            val url = URL(
                "https://firestore.googleapis.com/v1/projects/$projectId/" +
                    "databases/(default)/documents/emergencyEvents"
            )
            val conn = url.openConnection() as HttpURLConnection
            try {
                conn.requestMethod = "POST"
                conn.connectTimeout = 1500
                conn.readTimeout = 1500
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("Authorization", "Bearer $idToken")
                conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                code in 200..299
            } finally {
                conn.disconnect()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "emergency event POST failed", t)
            false
        }
    }

    private fun stringValue(v: String) = JSONObject().put("stringValue", v)
    private fun doubleValue(v: Double) = JSONObject().put("doubleValue", v)

    private fun rfc3339(ms: Long): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date(ms))
    }

    private fun writeEvent(prefs: android.content.SharedPreferences, event: JSONObject) {
        try {
            prefs.edit().putString(K_EVENT, event.toString()).apply()
        } catch (t: Throwable) {
            Log.w(TAG, "could not persist event record", t)
        }
    }
}
