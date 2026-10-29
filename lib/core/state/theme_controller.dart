import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide appearance setting: light (default), dark, or follow the system.
///
/// Kept as a simple [ValueNotifier] so the MaterialApp and the Profile
/// settings can both listen without extra plumbing.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.light);

const String _themeModeKey = 'theme_mode';

ThemeMode _themeModeFromId(String? id) {
  if (id == 'dark') return ThemeMode.dark;
  if (id == 'system') return ThemeMode.system;
  return ThemeMode.light;
}

String _themeModeId(ThemeMode mode) {
  if (mode == ThemeMode.dark) return 'dark';
  if (mode == ThemeMode.system) return 'system';
  return 'light';
}

/// Loads the persisted appearance setting. Defaults to light ("white").
Future<void> loadThemeMode() async {
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    themeModeNotifier.value = _themeModeFromId(prefs.getString(_themeModeKey));
  } catch (e) {
    // Keep the light default when storage is unavailable.
    debugPrint('Tourism: theme load failed: $e');
  }
}

/// Persists and applies a new appearance setting immediately.
Future<void> setThemeMode(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, _themeModeId(mode));
  } catch (e) {
    debugPrint('Tourism: theme save failed: $e');
  }
}
