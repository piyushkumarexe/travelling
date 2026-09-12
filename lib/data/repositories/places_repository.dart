import 'dart:async';
import 'dart:typed_data';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/free_geo_client.dart';
import '../../core/network/osrm_client.dart';
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

  List<Place> _decode(Map<String, dynamic> data) {
    final List<dynamic> raw =
        (data['places'] is List) ? data['places'] as List : <dynamic>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Place.fromJson)
        .toList();
  }

  Future<List<Place>> search(
    String query, {
    LatLng? location,
    double? radiusMeters,
    List<String>? types,
  }) async {
    final String q = query.trim();
    // Free providers FIRST (Overpass + MapTiler + Nominatim, merged and
    // distance-sorted) — this is the real working data on the Spark plan,
    // with no Cloud Functions dependency. Typed failures (network / rate
    // limit / unauthorized) propagate with honest messages.
    final List<Place> free = await _freeSearchWithCache(
      q,
      near: location,
      types: types,
      radiusMeters: radiusMeters ?? 10000,
    );
    if (free.isNotEmpty) return free;

    // Backend (Google Places proxy) only when configured AND the free
    // providers genuinely returned zero results — it is never a silent
    // fallback for provider errors.
    if (!configured) return free;
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
      return _decode(data);
    } on ApiException {
      return free; // empty — the UI shows the honest zero-results state.
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
    if (cached != null && cached.isNotEmpty) return cached;
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
      {double radiusMeters = 10000, bool force = false}) {
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
      {double radiusMeters = 10000, bool force = false}) {
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
