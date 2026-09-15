import 'dart:async';
import 'dart:typed_data';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/free_geo_client.dart';
import '../../core/network/osrm_client.dart';
import '../../core/utils/geo.dart';
import '../local/nearby_store.dart';
import '../local/search_cache.dart';
import '../models/places.dart';

/// Places / routes / geocoding.
///
/// Primary transport is the Tourism backend (Google Places proxy, server-side
/// key). When the backend is not deployed/unreachable, everything falls back
/// to free, real providers so Explore and the map keep working on-device:
/// MapTiler geocoding (search + reverse) and the OSRM public router.
///
/// Routing is always OSRM (free, keyless) — Google Routes is not used.
class PlacesRepository {
  PlacesRepository(this._api);

  final ApiClient _api;
  final FreeGeoClient _free = FreeGeoClient();
  final OsrmClient _osrm = OsrmClient();
  final NearbyStore _nearby = NearbyStore();

  /// Broadcast of background nearby-dataset refreshes — screens showing a
  /// stale (saved) dataset subscribe and swap in the fresh list the moment
  /// the network refresh lands.
  Stream<NearbyUpdate> get nearbyUpdates => _nearby.updates;

  List<Place> _decode(Map<String, dynamic> data) {
    final List<dynamic> raw =
        (data['places'] is List) ? data['places'] as List : <dynamic>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Place.fromJson)
        .toList();
  }

  // Precise fallback for Lucknow - avoids placeholder bug where janeshwar mishra park returns TS Mishra
  List<Place> _lucknowFallback(String query, LatLng? location) {
    final String q = query.toLowerCase().trim();
    final bool nearLucknow = location == null ||
        GeoUtils.distanceMeters(
                location, const LatLng(26.8467, 80.9462)) <=
            100000;
    if (!nearLucknow) return const <Place>[];
    final List<Place> out = <Place>[];
    final bool isJaneshwar = q.contains('janeshwar') || q.contains('janeshwer') || (q.contains('janesh') && q.contains('park'));
    final bool isTsMishra = q.contains('ts mishra') || q.contains('t s mishra') || q.contains('t.s. mishra') || (q.contains('mishra') && q.contains('university') && !isJaneshwar) || q == 'mishra university' || q.contains('tsmishra');
    if (isTsMishra && !isJaneshwar) {
      out.add(Place(
        placeId: 'lucknow-ts-mishra-university',
        name: 'TS Mishra University',
        lat: 26.8743,
        lng: 80.8521,
        address: 'Anora, Lucknow, Uttar Pradesh 227309',
        primaryType: 'university',
        types: const <String>['university', 'point_of_interest', 'establishment'],
        provider: 'local',
        city: 'Lucknow',
        state: 'Uttar Pradesh',
        country: 'India',
      ));
    }
    if (isJaneshwar || (q.contains('mishra') && q.contains('park') && !q.contains('ts mishra'))) {
      if (!q.contains('ts mishra')) {
        out.add(Place(
          placeId: 'lucknow-janeshwar-mishra-park',
          name: 'Janeshwar Mishra Park',
          lat: 26.8388,
          lng: 80.9960,
          address: 'Gomti Nagar, Lucknow, Uttar Pradesh',
          primaryType: 'park',
          types: const <String>['park', 'tourist_attraction', 'point_of_interest'],
          provider: 'local',
          city: 'Lucknow',
          state: 'Uttar Pradesh',
          country: 'India',
        ));
      }
    }
    if (q.contains('transport nagar')) {
      out.add(Place(
        placeId: 'lucknow-transport-nagar',
        name: 'Transport Nagar',
        lat: 26.8147,
        lng: 80.8912,
        address: 'Transport Nagar, Lucknow, Uttar Pradesh',
        primaryType: 'locality',
        types: const <String>['locality', 'political'],
        provider: 'local',
        city: 'Lucknow',
        state: 'Uttar Pradesh',
        country: 'India',
      ));
    }
    return out;
  }

  Future<List<Place>> search(
    String query, {
    LatLng? location,
    double? radiusMeters,
    List<String>? types,
  }) async {
    final String q = query.trim();

    // Check Lucknow fallback first - return immediately for precise known places only
    // Avoids placeholder bug: janeshwar mishra park should NOT return TS Mishra University
    final List<Place> fallback = _lucknowFallback(q, location);
    final String ql = q.toLowerCase();
    final bool isPreciseFallback = ql.contains('ts mishra') || ql.contains('transport nagar') || ql.contains('janeshwar mishra') || (ql.contains('janeshwar') && ql.contains('park'));
    if (fallback.isNotEmpty && isPreciseFallback) {
      List<Place> fb = List<Place>.from(fallback);
      if (location != null) {
        fb.sort((Place a, Place b) => _distance(a, location).compareTo(_distance(b, location)));
      }
      return fb;
    }
    
    // Try free providers first (Overpass + MapTiler + Photon + Nominatim)
    List<Place> free = <Place>[];
    try {
      free = await _freeSearchWithCache(
        q,
        near: location,
        types: types,
        radiusMeters: radiusMeters ?? 25000,
      );
    } catch (_) {
      free = <Place>[];
    }

    // Always try backend (Google Places TextSearch) as well when configured
    // - Google has better coverage for universities like "TS Mishra University"
    // Merge free + backend, dedup, and sort by distance for Nearby
    List<Place> backend = <Place>[];
    if (configured) {
      final Map<String, dynamic> body = <String, dynamic>{'query': q};
      if (location != null) {
        body['location'] = <String, double>{
          'lat': location.latitude,
          'lng': location.longitude,
        };
      }
      if (radiusMeters != null) body['radiusMeters'] = radiusMeters;
      if (types != null && types.isNotEmpty) body['types'] = types;
      try {
        final Map<String, dynamic> data = await _api.post('/placesSearch', body);
        backend = _decode(data);
      } catch (_) {
        backend = <Place>[];
      }
    }

    // Merge fallback + free + backend, dedup
    List<Place> allFree = [...fallback, ...free];
    if (allFree.isEmpty && backend.isEmpty) return const <Place>[];
    if (allFree.isEmpty) return backend;
    if (backend.isEmpty) {
      // Even if only fallback+free, sort by distance for Nearby
      if (location != null) {
        allFree.sort((Place a, Place b) => _distance(a, location).compareTo(_distance(b, location)));
      }
      return allFree;
    }

    // Merge and dedup
    final Map<String, Place> merged = <String, Place>{};
    for (final Place p in [...allFree, ...backend]) {
      final String key = '${p.name.toLowerCase().trim()}|${p.lat.toStringAsFixed(4)},${p.lng.toStringAsFixed(4)}';
      if (!merged.containsKey(key)) {
        merged[key] = p;
      }
    }
    List<Place> out = merged.values.toList();

    // If location available and Nearby, sort by distance and prioritize exact matches
    if (location != null) {
      // Sort by distance first for Nearby
      out.sort((Place a, Place b) {
        final double da = _distance(a, location);
        final double db = _distance(b, location);
        return da.compareTo(db);
      });
    }

    return out;
  }

  double _distance(Place p, LatLng from) {
    try {
      return GeoUtils.distanceMeters(from, p.coords);
    } catch (_) {
      return 0;
    }
  }

  /// Autocomplete suggestions while typing. Uses MapTiler Geocoding (which
  /// permits autocomplete) — never public Nominatim, which forbids it.
  Future<List<Place>> suggest(
    String query, {
    LatLng? location,
    int limit = 8,
  }) =>
      _free.suggest(query, near: location, limit: limit);

  /// Free-provider search with a short on-device cache so repeat searches in
  /// the same area are instant (no repeated network round-trips).
  Future<List<Place>> _freeSearchWithCache(
    String query, {
    LatLng? near,
    List<String>? types,
    double radiusMeters = 10000,
  }) async {
    final String cacheKey = SearchCache.key(
      query,
      types,
      near?.latitude,
      near?.longitude,
      radiusMeters,
    );
    final List<Place>? cached = await SearchCache.read(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      // Cached lists were written by whatever ranking existed at write time.
      // Re-apply local-first ranking + relevance so a stale or old-format
      // entry can never put far-away noise above the user's own area.
      if (types == null) {
        final List<Place> ranked =
            PlaceRanking.rankSuggestions(cached, query.trim(), near);
        final List<Place> relevant =
            PlaceRanking.filterRelevant(ranked, query.trim(), near);
        if (relevant.isNotEmpty) return relevant;
        // Cached entry is entirely irrelevant now (e.g. written by an old
        // build) — fall through to a fresh network search instead.
      } else {
        return cached;
      }
    }
    try {
      final List<Place> result = await _free.searchPlaces(
        query,
        near: near,
        types: types,
        radiusMeters: radiusMeters,
        filterToRadius: types != null,
      );
      if (result.isNotEmpty) {
        unawaited(SearchCache.write(cacheKey, result));
      }
      return result;
    } on ApiException catch (e) {
      // Offline / rate-limited / provider error → serve stale saved results
      // instead of surfacing a misleading failure when we have real data.
      if (e.kind == ApiErrorKind.network ||
          e.kind == ApiErrorKind.timeout ||
          e.kind == ApiErrorKind.rateLimited ||
          e.kind == ApiErrorKind.server ||
          e.kind == ApiErrorKind.parser) {
        final List<Place>? stale = await SearchCache.readStale(cacheKey);
        if (stale != null && stale.isNotEmpty) return stale;
      }
      rethrow;
    }
  }

  /// Combined nearby dataset (all essential categories) for a location,
  /// fetched once via a grouped Overpass query and cached per location
  /// bucket. Callers filter it locally by category — switching categories
  /// does NOT trigger another network request. On network/rate-limit
  /// failures a stale cached dataset is returned (flagged) instead of an
  /// error.
  Future<NearbyResult> nearbyAround(LatLng location,
      {double radiusMeters = FreeGeoClient.kNearbyRadiusMeters,
      bool force = false}) {
    return _nearby.load(
      location,
      force: force,
      variant: 'core',
      fetch: () => _free.nearbyAround(location, radiusMeters: radiusMeters),
    );
  }

  /// Shops only (`shop=*`) for the Shopping category — fetched on demand so
  /// the dense shop layer never crowds the essential POI dataset.
  Future<NearbyResult> nearbyShopping(LatLng location,
      {double radiusMeters = FreeGeoClient.kNearbyRadiusMeters,
      bool force = false}) {
    return _nearby.load(
      location,
      force: force,
      variant: 'shopping',
      fetch: () => _free.nearbyShopping(location, radiusMeters: radiusMeters),
    );
  }

  /// Validates the compiled MapTiler key with a single geocoding request.
  Future<bool> mapTilerKeyValid() => _free.mapTilerKeyValid();

  Future<Place?> details(String placeId) async {
    try {
      final Map<String, dynamic> data =
          await _api.post('/placesDetails', <String, dynamic>{
        'placeId': placeId,
      });
      final dynamic p = data['place'];
      if (p is Map<String, dynamic>) return Place.fromJson(p);
      return null;
    } on ApiException {
      // Details need the backend (ratings/photos). Return null so the UI can
      // fall back to the summary it already has.
      return null;
    }
  }

  Future<List<Place>> emergencyNearby(LatLng location,
      {double radiusMeters = 5000}) async {
    try {
      final Map<String, dynamic> data =
          await _api.post('/emergencyNearby', <String, dynamic>{
        'location': <String, double>{
          'lat': location.latitude,
          'lng': location.longitude,
        },
        'radiusMeters': radiusMeters,
      });
      return _decode(data);
    } on ApiException {
      final List<Place> all = <Place>[];
      for (final String q in <String>['hospital', 'police station', 'pharmacy']) {
        try {
          final List<Place> found = await _free.searchPlaces(q, near: location);
          for (final Place p in found) {
            if (all.length >= 20) break;
            if (!all.any((Place e) => e.placeId == p.placeId)) all.add(p);
          }
        } catch (_) {}
      }
      return all;
    }
  }

  Future<RouteInfo> route(LatLng from, LatLng to, {String mode = 'car'}) =>
      _free.route(from, to, mode: mode);

  /// Strict OSRM routing for the "Get Directions" flow: real road distance,
  /// ETA and a full GeoJSON polyline. Unlike [route], this throws
  /// [OsrmException] on failure (NoRoute / NoSegment / network / invalid
  /// coordinates) so the UI can show a specific, actionable message instead
  /// of a silent straight-line estimate.
  Future<RouteInfo> osrmRoute(LatLng from, LatLng to, {String mode = 'car'}) =>
      _osrm.route(origin: from, destination: to, mode: mode);

  Future<String?> reverseGeocode(LatLng location) async {
    try {
      final Map<String, dynamic> data =
          await _api.post('/geocodeReverse', <String, dynamic>{
        'lat': location.latitude,
        'lng': location.longitude,
      });
      final String? label = data['label'] as String?;
      if (label != null && label.trim().isNotEmpty) return label.trim();
      return null;
    } on ApiException {
      return _free.reverseGeocode(location.latitude, location.longitude);
    }
  }

  /// Fetches a Places photo through the backend proxy (keeps the Google key
  /// server-side).
  Future<Uint8List> photoBytes(String photoUrl) => _api.getBytes(photoUrl);

  /// Free Wikipedia photo + short description for a page title. Used so place
  /// details show a real picture even when the backend is offline.
  Future<(String?, String?)> wikipediaSummary(String title) =>
      _free.wikipediaSummary(title);

  /// Free Wikipedia thumbnail by free-text search (for places without a wiki
  /// URL). Returns an image URL or null.
  Future<String?> wikipediaThumbnailBySearch(String query) =>
      _free.wikipediaThumbnailBySearch(query);

  /// Opens real turn-by-turn navigation on the device: native Google Maps
  /// navigation first, then the Maps deep link, then a geo: URI.
  Future<bool> openInGoogleMaps(double lat, double lng, String? name) async {
    final Uri nav = Uri.parse('google.navigation:q=$lat,$lng');
    if (await canLaunchUrl(nav)) {
      await launchUrl(nav, mode: LaunchMode.externalApplication);
      return true;
    }
    final Uri web = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (await canLaunchUrl(web)) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
      return true;
    }
    final String label = name ?? 'destination';
    final Uri geo = Uri.parse(
        'geo:0,0?dlat=$lat&dlng=$lng&daddr=${Uri.encodeComponent(label)}');
    if (await canLaunchUrl(geo)) {
      await launchUrl(geo, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }

  /// Whether the backend base URL could be built (Firebase configured).
  bool get configured => _api.baseUrl.isNotEmpty;
}

/// Convenience: a stable, user-friendly error message for places errors.
String placesErrorMessage(Object e) {
  if (e is ApiException) {
    if (e.kind == ApiErrorKind.location) {
      return 'Your location is currently unavailable.';
    }
    return e.message;
  }
  return 'Could not load places. Please try again.';
}

/// Explore category chips: Attractions, Museums, Parks, Hotels, Food,
/// Shopping, Landmarks and Tourist places — each with an explicit OSM filter
/// mapping (see FreeGeoClient._typeFilters), never just a UI label.
const List<String> kExploreCategories = <String>[
  'tourist_attraction',
  'museum',
  'park',
  'hotel',
  'food',
  'shopping',
  'landmark',
  'tourist_places',
];

const Map<String, String> kExploreCategoryLabels = <String, String>{
  'tourist_attraction': 'Attractions',
  'museum': 'Museums',
  'park': 'Parks',
  'hotel': 'Hotels',
  'food': 'Food',
  'shopping': 'Shopping',
  'landmark': 'Landmarks',
  'tourist_places': 'Tourist places',
};
