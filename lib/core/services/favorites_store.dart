import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/places.dart';

/// On-device "saved places" list (wishlist). Works fully offline — no backend
/// needed — so travellers can save attractions/hotels and find them later.
class FavoritesStore {
  FavoritesStore._();

  static const String _key = 'favorite_places';

  static Future<List<Place>> all() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? raw = p.getString(_key);
      if (raw == null) return const <Place>[];
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(Place.fromJson)
          .toList();
    } catch (_) {
      return const <Place>[];
    }
  }

  static Future<Set<String>> ids() async {
    final List<Place> items = await all();
    return items.map((Place p) => p.placeId).toSet();
  }

  static Future<bool> contains(String placeId) async {
    final Set<String> s = await ids();
    return s.contains(placeId);
  }

  static Future<bool> toggle(Place place) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final List<Place> items = await all();
      final int i = items.indexWhere((Place e) => e.placeId == place.placeId);
      final bool wasSaved = i >= 0;
      if (wasSaved) {
        items.removeAt(i);
      } else {
        items.insert(0, place);
      }
      await p.setString(
          _key, jsonEncode(items.map((Place e) => e.toJson()).toList()));
      return !wasSaved;
    } catch (_) {
      return false;
    }
  }
}
