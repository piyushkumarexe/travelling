import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
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
    this.key,
  });

  final List<Place> places;
  final bool fromCache;
  final bool stale;

  /// Bucket key ("lat,lng|variant") of the dataset — used by UI listeners
  /// to match an async refresh back to what is on screen.
  final String? key;
}

/// Broadcast when a background (stale-while-revalidate) refresh completes:
/// the UI subscribes and swaps in the fresh list — previously the fresh data
/// only appeared on the NEXT screen open, which looked like "saved places
/// never update even with internet on".
class NearbyUpdate {
  const NearbyUpdate({required this.key, required this.result});
  final String key;
  final NearbyResult result;
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

  final StreamController<NearbyUpdate> _updates =
      StreamController<NearbyUpdate>.broadcast();

  /// Fires with fresh datasets as background refreshes land.
  Stream<NearbyUpdate> get updates => _updates.stream;

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
      // Cache HIT: no network request. The `[places]` dev log will NOT show a
      // new `overpass req#N` line for this call — that is the proof that
      // switching categories reuses the already-downloaded dataset.
      debugPrint('[places] nearbyStore HIT $key (${mem.places.length} places, '
          '${DateTime.now().difference(mem.fetchedAt).inSeconds}s old)');
      return NearbyResult(places: mem.places, fromCache: true);
    }

    // Stale-while-revalidate: show the last dataset IMMEDIATELY (even if
    // expired) and refresh in the background, so Explore/Essentials never
    // block on a slow Overpass round-trip when we already have real data.
    if (!force) {
      if (mem != null && mem.places.isNotEmpty) {
        debugPrint('[places] nearbyStore STALE-SWR $key '
            '(${mem.places.length} places, serving instantly + refreshing)');
        _backgroundRefresh(key, fetch);
        return NearbyResult(
            places: mem.places, fromCache: true, stale: true, key: key);
      }
      final List<Place>? persisted = await _read(key);
      if (persisted != null && persisted.isNotEmpty) {
        debugPrint('[places] nearbyStore DISK-SWR $key '
            '(${persisted.length} places, serving instantly + refreshing)');
        _backgroundRefresh(key, fetch);
        return NearbyResult(
            places: persisted, fromCache: true, stale: true, key: key);
      }
    }

    final Future<NearbyResult>? pending = _inFlight[key];
    if (pending != null) {
      debugPrint('[places] nearbyStore DEDUP $key (shared in-flight fetch)');
      return pending;
    }

    debugPrint('[places] nearbyStore FETCH $key (network fetch starting)');
    final Future<NearbyResult> run = _run(key, fetch);
    _inFlight[key] = run;
    try {
      return await run;
    } finally {
      if (identical(_inFlight[key], run)) unawaited(_inFlight.remove(key));
    }
  }

  /// Fires a background refresh (deduplicated) without blocking the caller;
  /// the fresh result replaces the in-memory bucket for the next open and is
  /// broadcast on [updates]. One automatic retry: Overpass mirrors rate-limit
  /// bursts, so a single failure used to leave "saved places" stuck for the
  /// whole session.
  void _backgroundRefresh(String key, Future<List<Place>> Function() fetch) {
    final Future<NearbyResult>? pending = _inFlight[key];
    if (pending != null) return; // already refreshing
    final Future<NearbyResult> run = _run(key, fetch);
    _inFlight[key] = run;
    unawaited(run.then(
      (NearbyResult _) {},
      onError: (Object _) async {
        // Retry once after a short backoff, still deduplicated.
        await Future<void>.delayed(const Duration(seconds: 6));
        if (!_inFlight.containsKey(key)) {
          final Future<NearbyResult> retry = _run(key, fetch);
          _inFlight[key] = retry;
          unawaited(retry.whenComplete(() {
            if (identical(_inFlight[key], retry)) _inFlight.remove(key);
          }));
        }
      },
    ).whenComplete(() {
      if (identical(_inFlight[key], run)) _inFlight.remove(key);
    }));
  }

  Future<NearbyResult> _run(
    String key,
    Future<List<Place>> Function() fetch,
  ) async {
    try {
      final List<Place> places = await fetch();
      _mem[key] = _Bucket(DateTime.now(), places);
      if (places.isNotEmpty) unawaited(_persist(key, places));
      final NearbyResult fresh = NearbyResult(places: places, key: key);
      // Tell waiting screens the live data has landed (see NearbyUpdate).
      if (!_updates.isClosed) {
        _updates.add(NearbyUpdate(key: key, result: fresh));
      }
      return fresh;
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
