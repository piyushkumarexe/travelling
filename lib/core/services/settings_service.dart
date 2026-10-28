import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-device app preferences (nothing sensitive, never uploaded).
///
/// Persisted with [SharedPreferences] so settings work fully offline and do
/// not depend on Firebase/Cloud Functions at all.
class SettingsService extends ChangeNotifier {
  static const String _kAutoReadReplies = 'settings.auto_read_replies';
  static const String _kPowerOffSafety = 'power_off_safety.enabled';
  static const String _kOfflineEmergencySms =
      'offline_emergency_sms.enabled';
  static const String _kOfflineEmergencyLastStatus =
      'offline_emergency_sms.last_status';
  static const String _kBehaviourPackedness = 'behaviour.packedness.v1';

  // SOS contact: device-local source of truth shared by the SOS screen and
  // Profile (Power-Off Safety Location). Stored locally so adding/editing/
  // removing a contact ALWAYS works offline and survives restart, regardless
  // of Firestore rules/auth state. Firestore profiles/{uid} is mirrored
  // best-effort for cross-device sync.
  static const String _kSosContactName = 'sos_contact.name';
  static const String _kSosContactPhone = 'sos_contact.phone';

  // Payload keys mirrored for the native Android shutdown receiver. The
  // SharedPreferences plugin prefixes keys with "flutter." on Android.
  static const String _kPowerOffPhone = 'power_off_safety.sos_phone';
  static const String _kPowerOffName = 'power_off_safety.sos_name';
  static const String _kPowerOffProject = 'power_off_safety.project_id';
  static const String _kPowerOffToken = 'power_off_safety.id_token';
  static const String _kPowerOffLastEvent = 'power_off_safety.last_event';

  bool _autoReadReplies = false;
  bool _powerOffSafety = false;
  bool _offlineEmergencySms = false;
  String _offlineEmergencyLastStatus = '';
  String _sosContactName = '';
  String _sosContactPhone = '';

  /// Whether the AI assistant should speak every new reply aloud.
  /// Defaults to OFF.
  bool get autoReadReplies => _autoReadReplies;

  /// Power-Off Safety Location. Defaults to OFF. When ON, the app mirrors the
  /// latest available location + SOS contact to local storage so the native
  /// shutdown receiver can make a best-effort share attempt while the device
  /// is shutting down. It NEVER claims a fresh GPS fix after power-off.
  bool get powerOffSafety => _powerOffSafety;

  /// Offline Emergency Location SMS. Defaults to OFF — the user must enable
  /// it explicitly. When ON, SOS actions (and the shutdown flow) also send a
  /// plain cellular SMS with the device location via the native SmsManager —
  /// no internet involved. SMS still needs SIM/cellular signal; that limit
  /// is shown honestly in the UI.
  bool get offlineEmergencySms => _offlineEmergencySms;

  /// Human-readable result of the last offline-SMS attempt (locally
  /// persisted, never logged elsewhere). Empty until the first attempt.
  String get offlineEmergencyLastStatus => _offlineEmergencyLastStatus;

  Future<void> setOfflineEmergencyLastStatus(String status) async {
    _offlineEmergencyLastStatus = status;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kOfflineEmergencyLastStatus, status);
    } catch (_) {}
    notifyListeners();
  }

  /// SOS contact (device-local source of truth).
  String get sosContactName => _sosContactName;
  String get sosContactPhone => _sosContactPhone;
  bool get hasSosContact =>
      _sosContactName.trim().isNotEmpty || _sosContactPhone.trim().isNotEmpty;

  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _autoReadReplies = prefs.getBool(_kAutoReadReplies) ?? false;
      _powerOffSafety = prefs.getBool(_kPowerOffSafety) ?? false;
      _offlineEmergencySms =
          prefs.getBool(_kOfflineEmergencySms) ?? false;
      _offlineEmergencyLastStatus =
          prefs.getString(_kOfflineEmergencyLastStatus) ?? '';
      _behaviourPackedness = (prefs.getStringList(_kBehaviourPackedness) ??
              const <String>[])
          .map((String e) => double.tryParse(e) ?? 0)
          .toList();
      _sosContactName = prefs.getString(_kSosContactName) ?? '';
      _sosContactPhone = prefs.getString(_kSosContactPhone) ?? '';
    } catch (_) {
      _autoReadReplies = false;
      _powerOffSafety = false;
      _offlineEmergencySms = false;
      _offlineEmergencyLastStatus = '';
      _behaviourPackedness = const <double>[];
      _sosContactName = '';
      _sosContactPhone = '';
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

  // ---- personal behaviour model (non-sensitive, action-derived) ----
  // Records ONLY the packedness (stops/day) of plans the user actually
  // applied in Travel Intelligence. No location history, no identities.

  List<double> _behaviourPackedness = <double>[];

  Future<void> recordBehaviour({required double packedness}) async {
    _behaviourPackedness = <double>[..._behaviourPackedness, packedness];
    if (_behaviourPackedness.length > 20) {
      _behaviourPackedness = _behaviourPackedness.sublist(
          _behaviourPackedness.length - 20);
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _kBehaviourPackedness,
          _behaviourPackedness.map((double v) => v.toStringAsFixed(1)).toList());
    } catch (_) {}
    notifyListeners();
  }

  /// Human-readable summary from real recorded actions; honest when empty.
  List<String> behaviourSummary() {
    if (_behaviourPackedness.isEmpty) {
      return const <String>[
        'No planning behaviour recorded yet. Apply a What-If, recovery or '
            'constraint plan and your pacing preference (stops per day) is '
            'learned here.'
      ];
    }
    final double avg = _behaviourPackedness.fold<double>(
            0, (double a, double v) => a + v) /
        _behaviourPackedness.length;
    final String pace = avg >= 5
        ? 'packed days (many stops)'
        : avg >= 3.5
            ? 'balanced days'
            : 'relaxed days (few stops)';
    return <String>[
      'Preferred pacing: $pace (average ${avg.toStringAsFixed(1)} stops/day '
          'across ${_behaviourPackedness.length} applied plan(s)).',
    ];
  }

  Future<void> resetBehaviour() async {
    _behaviourPackedness = <double>[];
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kBehaviourPackedness);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setOfflineEmergencySms(bool value) async {
    _offlineEmergencySms = value;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kOfflineEmergencySms, value);
    } catch (_) {
      // In-memory value still applies.
    }
  }

  /// Saves the SOS contact locally (instant, offline-safe, survives restart).
  /// Setting a contact also powers the Power-Off Safety Location share payload.
  Future<void> setSosContact(String name, String phone) async {
    _sosContactName = name.trim();
    _sosContactPhone = phone.trim();
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSosContactName, _sosContactName);
      await prefs.setString(_kSosContactPhone, _sosContactPhone);
    } catch (_) {
      // Persistence is best-effort; the in-memory value still applies.
    }
  }

  /// Clears the SOS contact. Power-Off Safety Location must be turned off
  /// separately (it requires a contact).
  Future<void> clearSosContact() async {
    _sosContactName = '';
    _sosContactPhone = '';
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kSosContactName);
      await prefs.remove(_kSosContactPhone);
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
