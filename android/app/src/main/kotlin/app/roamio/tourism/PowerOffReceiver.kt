package app.roamio.tourism

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
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
 * The Flutter side (SettingsService / Profile) mirrors the enabled flag, the
 * configured SOS contact, the Firebase project id + a fresh ID token, and the
 * last-known GPS fix into SharedPreferences (the shared_preferences plugin
 * writes keys prefixed with "flutter."). When Android broadcasts
 * [Intent.ACTION_SHUTDOWN], this receiver reads that local state and attempts
 * ONE best-effort share: it writes the emergency event to the project's
 * Firestore `emergencyEvents` collection (the same collection the app's SOS
 * flow uses) via the Firestore REST API.
 *
 * Hard technical limits (documented honestly in the app):
 *  - It can only reuse the LATEST AVAILABLE location. It never claims to
 *    obtain a new GPS fix after the phone is off — that is impossible.
 *  - The shutdown window is short and the network is often already down, so
 *    the attempt frequently cannot be confirmed. We record `sendConfirmed`
 *    ONLY on a real 2xx response; otherwise the event is marked
 *    "Send could not be confirmed." — delivery is never fabricated.
 *  - No background service, no foreground service and no new permissions are
 *    required for this: it is a manifest-registered receiver that does a
 *    single, short, fire-and-forget network call during shutdown.
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
        if (intent.action != Intent.ACTION_SHUTDOWN) return
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
        if (!confirmed) event.put("note", "Send could not be confirmed.")
        writeEvent(prefs, event)
    }

    private fun readLocation(prefs: android.content.SharedPreferences): Pair<Double, Double>? {
        val raw = prefs.getString(K_LAST_POS, null) ?: return null
        return try {
            val json = JSONObject(raw)
            val lat = json.optDouble("latitude")
            val lng = json.optDouble("longitude")
            if (lat.isNaN() || lng.isNaN() || lat == 0.0 && lng == 0.0) null
            else Pair(lat, lng)
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
