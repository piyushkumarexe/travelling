import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/places.dart';

/// On-device cache for place searches, so repeat lookups in the same area
/// open instantly instead of hitting the network every time. Entries expire
/// after a short TTL.
class SearchCache {
  SearchCache._();

  static const Duration ttl = Duration(minutes: 30);

  static String key(
    String query,
    List<String>? types,
    double? lat,
    double? lng,
    double radiusMeters,
  ) {
    final String loc = (lat == null || lng == null)
        ? 'global'
        : '${lat.toStringAsFixed(2)},${lng.toStringAsFixed(2)}';
    final String t = (types ?? const <String>[]).join('+');
    return 'places_cache_${Uri.encodeComponent(query.trim().toLowerCase())}'
        '|$t|$loc|${radiusMeters.round()}';
  }

  static Future<List<Place>?> read(String key) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? raw = p.getString(key);
      if (raw == null) return null;
      final Map<String, dynamic> m =
          (jsonDecode(raw) as Map).map((Object? k, Object? v) =>
              MapEntry(k.toString(), v));
      final int ts = (m['t'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > ttl.inMilliseconds) {
        return null;
      }
      final Object? list = m['p'];
      if (list is! List) return null;
      return list
          .whereType<Map<String, dynamic>>()
          .map(Place.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, List<Place> places) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(
        key,
        jsonEncode(<String, dynamic>{
          't': DateTime.now().millisecondsSinceEpoch,
          'p': places.map((Place e) => e.toJson()).toList(),
        }),
      );
    } catch (_) {}
  }
}
