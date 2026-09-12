import 'dart:async';
import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/api_exception.dart';
import '../models/places.dart';

/// Result of a nearby-dataset load. [fromCache] tells the UI the data was not
/// freshly fetched, and [stale] additionally means the cache had expired or
/// the network failed — so the UI can honestly say "showing saved results"
/// instead of pretending fresh data arrived.
class NearbyResult {
  const NearbyResult({
    required this.places,
    this.fromCache = false,
    this.stale = false,
  });

  final List<Place> places;
  final bool fromCache;
  final bool stale;
}

class _Bucket {
  const _Bucket(this.fetchedAt, this.places);
  final DateTime fetchedAt;
  final List<Place> places;
}

/// Caches the combined nearby dataset per location bucket, so the app does
/// NOT re-query Overpass every time the user opens a screen, switches a
/// category, or moves a small distance. Fetch once → filter locally.
///
/// Also deduplicates in-flight requests: concurrent callers for the same
/// bucket share ONE request instead of firing duplicates.
class NearbyStore {
  static const Duration ttl = Duration(minutes: 15);
  static const int _maxPersisted = 200;
  static const String _prefix = 'nearby_dataset_';

  final Map<String, _Bucket> _mem = <String, _Bucket>{};
  final Map<String, Future<NearbyResult>> _inFlight =
      <String, Future<NearbyResult>>{};

  /// Location bucket: ~1.1 km grid cell (2 decimal places). Movement within
  /// the cell reuses the cached dataset; a meaningful move or TTL expiry
  /// triggers a refresh.
  static String bucketKey(LatLng p) =>
      '${p.latitude.toStringAsFixed(2)},${p.longitude.toStringAsFixed(2)}';

  Future<NearbyResult> load(
    LatLng location, {
    required Future<List<Place>> Function() fetch,
    bool force = false,
    String variant = 'core',
  }) async {
    final String key = '${bucketKey(location)}|$variant';
    final _Bucket? mem = _mem[key];
    if (!force && mem != null && DateTime.now().difference(mem.fetchedAt) < ttl) {
      return NearbyResult(places: mem.places, fromCache: true);
    }
    final Future<NearbyResult>? pending = _inFlight[key];
    if (pending != null) return pending;

    final Future<NearbyResult> run = _run(key, fetch);
    _inFlight[key] = run;
    try {
      return await run;
    } finally {
      if (identical(_inFlight[key], run)) unawaited(_inFlight.remove(key));
    }
  }

  Future<NearbyResult> _run(
    String key,
    Future<List<Place>> Function() fetch,
  ) async {
    try {
      final List<Place> places = await fetch();
      _mem[key] = _Bucket(DateTime.now(), places);
      if (places.isNotEmpty) unawaited(_persist(key, places));
      return NearbyResult(places: places);
    } on ApiException catch (e) {
      // Offline / rate-limited / provider error: serve the best cached data
      // we have instead of converting the failure into "no places found".
      if (e.kind == ApiErrorKind.network ||
          e.kind == ApiErrorKind.timeout ||
          e.kind == ApiErrorKind.rateLimited ||
          e.kind == ApiErrorKind.server ||
          e.kind == ApiErrorKind.parser) {
        final _Bucket? mem = _mem[key];
        if (mem != null && mem.places.isNotEmpty) {
          return NearbyResult(places: mem.places, fromCache: true, stale: true);
        }
        final List<Place>? persisted = await _read(key);
        if (persisted != null && persisted.isNotEmpty) {
          return NearbyResult(
              places: persisted, fromCache: true, stale: true);
        }
      }
      rethrow;
    }
  }

  Future<void> _persist(String key, List<Place> places) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<Place> bounded =
          places.length > _maxPersisted ? places.sublist(0, _maxPersisted) : places;
      await prefs.setString(
        '$_prefix$key',
        jsonEncode(<String, dynamic>{
          't': DateTime.now().millisecondsSinceEpoch,
          'p': bounded.map((Place e) => e.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Persistence is best-effort.
    }
  }

  Future<List<Place>?> _read(String key) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('$_prefix$key');
      if (raw == null) return null;
      final Map<String, dynamic> m =
          (jsonDecode(raw) as Map).map((Object? k, Object? v) =>
              MapEntry(k.toString(), v));
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
}
