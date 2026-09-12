import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-device app preferences (nothing sensitive, never uploaded).
///
/// Persisted with [SharedPreferences] so settings work fully offline and do
/// not depend on Firebase/Cloud Functions at all.
class SettingsService extends ChangeNotifier {
  static const String _kAutoReadReplies = 'settings.auto_read_replies';

  bool _autoReadReplies = false;

  /// Whether the AI assistant should speak every new reply aloud.
  /// Defaults to OFF.
  bool get autoReadReplies => _autoReadReplies;

  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _autoReadReplies = prefs.getBool(_kAutoReadReplies) ?? false;
    } catch (_) {
      _autoReadReplies = false;
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
}
