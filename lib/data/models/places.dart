import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A place returned by the Tourism backend (Google Places proxy).

class Place {
  Place({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lng,
    this.address,
    this.rating,
    this.userRatingCount,
    this.primaryType,
    this.types = const <String>[],
    this.photoUrls = const <String>[],
    this.phone,
    this.website,
    this.priceLevel,
    this.openNow,
  });

  final String placeId;
  final String name;
  final double lat;
  final double lng;
  final String? address;
  final double? rating;
  final int? userRatingCount;
  final String? primaryType;
  final List<String> types;
  final List<String> photoUrls;
  final String? phone;
  final String? website;
  final int? priceLevel;
  final bool? openNow;

  factory Place.fromJson(Map<String, dynamic> m) => Place(
        placeId: (m['placeId'] as String?) ?? '',
        name: (m['name'] as String?) ?? 'Unknown place',
        lat: (m['lat'] as num?)?.toDouble() ?? 0,
        lng: (m['lng'] as num?)?.toDouble() ?? 0,
        address: m['address'] as String?,
        rating: (m['rating'] as num?)?.toDouble(),
        userRatingCount: (m['userRatingCount'] as num?)?.toInt(),
        primaryType: m['primaryType'] as String?,
        types: (m['types'] is List)
            ? (m['types'] as List).whereType<String>().toList()
            : <String>[],
        photoUrls: (m['photoUrls'] is List)
            ? (m['photoUrls'] as List).whereType<String>().toList()
            : <String>[],
        phone: m['phone'] as String?,
        website: m['website'] as String?,
        priceLevel: (m['priceLevel'] as num?)?.toInt(),
        openNow: m['openNow'] as bool?,
      );

  LatLng get coords => LatLng(lat, lng);

  bool get isTourist => types.contains('tourist_attraction');
  bool get isFood =>
      types.contains('restaurant') ||
      types.contains('cafe') ||
      types.contains('bar') ||
      types.contains('food');
  bool get isEmergency =>
      types.contains('hospital') ||
      types.contains('police_station') ||
      types.contains('fire_station');
}

/// Route result: real Directions API output when available, otherwise an
/// honest straight-line fallback clearly labelled as approximate.
class RouteInfo {
  RouteInfo({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.polyline,
    required this.provider,
  });

  final double distanceMeters;
  final double durationSeconds;
  final List<LatLng> polyline;

  /// google (Directions API) | fallback (straight line estimate)
  final String provider;

  bool get isApproximate => provider != 'google';

  factory RouteInfo.fromJson(Map<String, dynamic> m) {
    final List<dynamic> raw = (m['polyline'] is List) ? m['polyline'] as List : <dynamic>[];
    return RouteInfo(
      distanceMeters: (m['distanceMeters'] as num?)?.toDouble() ?? 0,
      durationSeconds: (m['durationSeconds'] as num?)?.toDouble() ?? 0,
      polyline: raw
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> p) => LatLng(
                (p['lat'] as num?)?.toDouble() ?? 0,
                (p['lng'] as num?)?.toDouble() ?? 0,
              ))
          .toList(),
      provider: (m['provider'] as String?) ?? 'fallback',
    );
  }
}
