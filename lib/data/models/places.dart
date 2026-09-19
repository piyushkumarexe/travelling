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
    this.category,
    this.provider,
    this.distanceMeters,
    this.metadata = const <String, dynamic>{},
    this.city,
    this.state,
    this.country,
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

  /// Canonical OSM-derived category (hotel, hospital, museum, transit, …).
  /// Null when the place came from a text/geocoding search that has no
  /// category mapping. Never fabricated.
  final String? category;

  /// Which provider produced this record (overpass, maptiler, nominatim,
  /// wikipedia, …). Useful for diagnostics and deduplication.
  final String? provider;

  /// Haversine distance from the search/fetch origin, when known. Computed,
  /// never invented; may be null when the origin was not known.
  final double? distanceMeters;

  /// Provider-specific extras (OSM tags, etc.). Never fabricated.
  final Map<String, dynamic> metadata;

  /// Structured locality context, when the provider supplies it (MapTiler
  /// context / Photon properties / Nominatim address). Null = unknown —
  /// never fabricated. Used for locality-aware ranking and for showing
  /// "Name — Area, City" context when same-named places exist in several
  /// cities.
  final String? city;
  final String? state;
  final String? country;

  /// " — Area, City, State" context suffix (without the name), for
  /// disambiguating same-named places. Empty when nothing is known.
  String get contextLine {
    final List<String> parts = <String>[
      if (address != null && address!.isNotEmpty && address != name)
        address!,
      if (city != null && city!.isNotEmpty &&
          (address == null || !(address!.contains(city!)))) city!,
      if (state != null && state!.isNotEmpty) state!,
      if (country != null && country!.isNotEmpty && (state == null)) country!,
    ];
    final List<String> seen = <String>[];
    for (final String part in parts) {
      final String t = part.trim();
      if (t.isNotEmpty && !seen.contains(t)) seen.add(t);
    }
    return seen.isEmpty ? '' : ' — ${seen.join(', ')}';
  }

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
        category: m['category'] as String?,
        provider: m['provider'] as String?,
        distanceMeters: (m['distanceMeters'] as num?)?.toDouble(),
        metadata: (m['metadata'] is Map)
            ? (m['metadata'] as Map).map((Object? k, Object? v) =>
                MapEntry(k.toString(), v))
            : <String, dynamic>{},
        city: m['city'] as String?,
        state: m['state'] as String?,
        country: m['country'] as String?,
      );

  LatLng get coords => LatLng(lat, lng);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'placeId': placeId,
        'name': name,
        'lat': lat,
        'lng': lng,
        'address': address,
        'rating': rating,
        'userRatingCount': userRatingCount,
        'primaryType': primaryType,
        'types': types,
        'photoUrls': photoUrls,
        'phone': phone,
        'website': website,
        'priceLevel': priceLevel,
        'openNow': openNow,
        'category': category,
        'provider': provider,
        'distanceMeters': distanceMeters,
        'metadata': metadata,
        // Preserve locality context in the on-device cache as well as in
        // network responses; same-named branches must remain disambiguated
        // after an offline/cache hit.
        'city': city,
        'state': state,
        'country': country,
      };

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

  /// google (Directions API) | osrm (OSRM router) | fallback (straight line)
  final String provider;

  bool get isApproximate => provider == 'fallback';

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
