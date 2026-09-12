import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-device app preferences (nothing sensitive, never uploaded).
///
/// Persisted with [SharedPreferences] so settings work fully offline and do
/// not depend on Firebase/Cloud Functions at all.
class SettingsService extends ChangeNotifier {
  static const String _kAutoReadReplies = 'settings.auto_read_replies';
  static const String _kPowerOffSafety = 'power_off_safety.enabled';

  // Payload keys mirrored for the native Android shutdown receiver. The
  // SharedPreferences plugin prefixes keys with "flutter." on Android.
  static const String _kPowerOffPhone = 'power_off_safety.sos_phone';
  static const String _kPowerOffName = 'power_off_safety.sos_name';
  static const String _kPowerOffProject = 'power_off_safety.project_id';
  static const String _kPowerOffToken = 'power_off_safety.id_token';
  static const String _kPowerOffLastEvent = 'power_off_safety.last_event';

  bool _autoReadReplies = false;
  bool _powerOffSafety = false;

  /// Whether the AI assistant should speak every new reply aloud.
  /// Defaults to OFF.
  bool get autoReadReplies => _autoReadReplies;

  /// Power-Off Safety Location. Defaults to OFF. When ON, the app mirrors the
  /// latest available location + SOS contact to local storage so the native
  /// shutdown receiver can make a best-effort share attempt while the device
  /// is shutting down. It NEVER claims a fresh GPS fix after power-off.
  bool get powerOffSafety => _powerOffSafety;

  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _autoReadReplies = prefs.getBool(_kAutoReadReplies) ?? false;
      _powerOffSafety = prefs.getBool(_kPowerOffSafety) ?? false;
    } catch (_) {
      _autoReadReplies = false;
      _powerOffSafety = false;
    }
    notifyListeners();
  }

  Future<void> setAutoReadReplies(bool value) async {
    _autoReadReplies = value;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoReadReplies, value);
    } catch (_) {
      // Persistence is best-effort; the in-memory value still applies.
    }
  }

  Future<void> setPowerOffSafety(bool value) async {
    _powerOffSafety = value;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPowerOffSafety, value);
      if (!value) {
        // Turning OFF must never leave a stale share payload behind.
        await prefs.remove(_kPowerOffToken);
      }
    } catch (_) {
      // Persistence is best-effort; the in-memory value still applies.
    }
  }

  /// Mirrors the SOS contact + project info (and a fresh Firebase ID token)
  /// into local storage for the native shutdown receiver. Only meaningful
  /// while the feature is ON. Never logs the token.
  Future<void> syncPowerOffSafetyPayload({
    required String sosPhone,
    required String sosName,
    required String projectId,
    String? idToken,
  }) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPowerOffPhone, sosPhone);
      await prefs.setString(_kPowerOffName, sosName);
      await prefs.setString(_kPowerOffProject, projectId);
      if (idToken != null && idToken.isNotEmpty) {
        await prefs.setString(_kPowerOffToken, idToken);
      }
    } catch (_) {
      // Best-effort mirror.
    }
  }

  /// The last power-off event record written by the native receiver (raw
  /// JSON), or null when none has been recorded yet.
  Future<String?> powerOffLastEvent() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kPowerOffLastEvent);
    } catch (_) {
      return null;
    }
  }
}
