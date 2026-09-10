import 'dart:typed_data';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../models/places.dart';

/// Places / routes / geocoding — all proxied through the Roamio backend so
/// the Google API key never ships in the app.
class PlacesRepository {
  PlacesRepository(this._api);

  final ApiClient _api;

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
    final Map<String, dynamic> body = <String, dynamic>{'query': query.trim()};
    if (location != null) {
      body['location'] = <String, double>{
        'lat': location.latitude,
        'lng': location.longitude,
      };
    }
    if (radiusMeters != null) body['radiusMeters'] = radiusMeters;
    if (types != null && types.isNotEmpty) body['types'] = types;
    final Map<String, dynamic> data = await _api.post('/placesSearch', body);
    return _decode(data);
  }

  Future<Place?> details(String placeId) async {
    final Map<String, dynamic> data =
        await _api.post('/placesDetails', <String, dynamic>{
      'placeId': placeId,
    });
    final dynamic p = data['place'];
    if (p is Map<String, dynamic>) return Place.fromJson(p);
    return null;
  }

  Future<List<Place>> emergencyNearby(LatLng location,
      {double radiusMeters = 5000}) async {
    final Map<String, dynamic> data =
        await _api.post('/emergencyNearby', <String, dynamic>{
      'location': <String, double>{
        'lat': location.latitude,
        'lng': location.longitude,
      },
      'radiusMeters': radiusMeters,
    });
    return _decode(data);
  }

  Future<RouteInfo> route(LatLng from, LatLng to) async {
    final Map<String, dynamic> data =
        await _api.post('/route', <String, dynamic>{
      'origin': <String, double>{'lat': from.latitude, 'lng': from.longitude},
      'destination': <String, double>{
        'lat': to.latitude,
        'lng': to.longitude,
      },
    });
    return RouteInfo.fromJson(data);
  }

  Future<String?> reverseGeocode(LatLng location) async {
    final Map<String, dynamic> data =
        await _api.post('/geocodeReverse', <String, dynamic>{
      'lat': location.latitude,
      'lng': location.longitude,
    });
    final String? label = data['label'] as String?;
    if (label != null && label.trim().isNotEmpty) return label.trim();
    return null;
  }

  /// Fetches a Places photo through the backend proxy (keeps the Google key
  /// server-side).
  Future<Uint8List> photoBytes(String photoUrl) => _api.getBytes(photoUrl);

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
  if (e is ApiException) return e.message;
  return 'Could not load places. Please try again.';
}

/// Fallback icon list (Material-style, no external assets needed).
const List<String> kExploreCategories = <String>[
  'tourist_attraction',
  'restaurant',
  'cafe',
  'park',
  'museum',
  'hotel',
  'shopping_mall',
];

const Map<String, String> kExploreCategoryLabels = <String, String>{
  'tourist_attraction': 'Attractions',
  'restaurant': 'Restaurants',
  'cafe': 'Cafés',
  'park': 'Parks',
  'museum': 'Museums',
  'hotel': 'Hotels',
  'shopping_mall': 'Shopping',
};

/// "Hidden / local" queries are real Places queries, not a fake list.
const List<String> kHiddenGemsQueries = <String>[
  'hidden gem near here',
  'local spot near here',
  'under the radar tourist spot',
];
