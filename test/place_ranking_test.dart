import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;

import 'package:yatrawise/core/network/free_geo_client.dart';
import 'package:yatrawise/data/models/places.dart';

Place _p(String name, double lat, double lng, {String? address,
    String? city, String? state, String? country}) => Place(
      placeId: 'test-$name-$lat,$lng',
      name: name,
      lat: lat,
      lng: lng,
      address: address,
      city: city,
      state: state,
      country: country,
      primaryType: 'place',
      types: const <String>['point_of_interest'],
      provider: 'test',
    );

void main() {
  // Lucknow city centre (the traveller's area in the reported bug).
  final gm.LatLng lucknow = const gm.LatLng(26.8467, 80.9462);

  group('PlaceRanking — accuracy-first suggestions', () {
    test('among same-named places, the NEAREST is on top', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[
          _p('Transport Nagar', 28.6139, 77.2090, address: 'Delhi'), // far
          _p('Transport Nagar', 26.8000, 80.9000, address: 'Lucknow'), // near
        ],
        'transport nagar',
        lucknow,
      );
      expect(ranked.first.address, 'Lucknow');
    });

    test('exact name beats a closer weak (boundary) match', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[
          // 500 m away but only a word-boundary match.
          _p('Transport Nagar Metro Station', 26.8480, 80.9470),
          // 8 km away but the exact queried name.
          _p('Transport Nagar', 26.8000, 80.9000, address: 'Lucknow'),
        ],
        'transport nagar',
        lucknow,
      );
      expect(ranked.first.name, 'Transport Nagar');
    });

    test('starts-with beats word-boundary', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[
          _p('Hazratganj Market', 26.8500, 80.9470),
          _p('Hazratganj', 26.8490, 80.9460),
        ],
        'hazratganj',
        lucknow,
      );
      expect(ranked.first.name, 'Hazratganj');
    });

    test('token order does not matter ("lucknow transport nagar")', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[
          _p('Transport Nagar', 26.8000, 80.9000, address: 'Lucknow'),
          _p('Some Random Shop', 26.8468, 80.9463), // much closer, no match
        ],
        'lucknow transport nagar',
        lucknow,
      );
      expect(ranked.first.name, 'Transport Nagar');
    });

    test('locality still wins within the same match quality', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[
          _p('Charbagh', 19.0760, 72.8777, address: 'Mumbai'),
          _p('Charbagh', 26.8310, 80.9200, address: 'Lucknow'),
        ],
        'charbagh',
        lucknow,
      );
      expect(ranked.first.address, 'Lucknow');
    });

    test('EXPLICIT CITY in query beats GPS proximity ("taj mahal agra")', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[
          // Nearby same-name place in the traveller's own city.
          _p('Taj Mahal Restaurant', 26.8500, 80.9470, address: 'Lucknow'),
          // The real monument — far away, but the query names Agra.
          _p('Taj Mahal', 27.1751, 78.0421,
              address: 'Dharmapuri, Forest Colony, Agra',
              city: 'Agra', state: 'Uttar Pradesh', country: 'India'),
        ],
        'taj mahal agra',
        lucknow,
      );
      expect(ranked.first.name, 'Taj Mahal');
      expect(ranked.first.city, 'Agra');
    });

    test('without explicit city, nearby same-name wins ("abc cafe")', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[
          _p('ABC Cafe', 28.6139, 77.2090, address: 'Connaught Place, Delhi',
              city: 'Delhi'),
          _p('ABC Cafe', 26.8500, 80.9440, address: 'Gomti Nagar, Lucknow',
              city: 'Lucknow'),
        ],
        'abc cafe',
        lucknow,
      );
      expect(ranked.first.address, contains('Lucknow'));
    });

    test('subtitles show disambiguating context + distance', () {
      // Far enough from the origin that the formatter reports km (the
      // formatter correctly uses metres under 1 km).
      final Place distantCafe = _p('ABC Cafe', 27.0500, 81.1500,
          address: 'Gomti Nagar', city: 'Lucknow', state: 'Uttar Pradesh');
      final String sub =
          PlaceRanking.subtitleFor(distantCafe, lucknow);
      expect(sub, contains('Lucknow'));
      expect(sub, contains('km'));
    });

    test('structured locality is parsed from place data (model roundtrip)',
        () {
      final Place p = Place.fromJson(const <String, dynamic>{
        'placeId': 'mt.123',
        'name': 'ABC Cafe',
        'lat': 26.85,
        'lng': 80.944,
        'address': 'Gomti Nagar, Lucknow, Uttar Pradesh, India',
        'city': 'Lucknow',
        'state': 'Uttar Pradesh',
        'country': 'India',
      });
      expect(p.city, 'Lucknow');
      expect(p.state, 'Uttar Pradesh');
      expect(p.contextLine, contains('Lucknow'));
    });

    test('cached place serialization preserves locality disambiguation', () {
      final Place original = _p(
        'New Public College',
        26.80,
        80.90,
        address: 'Amar Shaheed Path',
        city: 'Lucknow',
        state: 'Uttar Pradesh',
        country: 'India',
      );
      final Place restored = Place.fromJson(original.toJson());
      expect(restored.city, 'Lucknow');
      expect(restored.state, 'Uttar Pradesh');
      expect(restored.contextLine, contains('Amar Shaheed Path'));
      expect(restored.contextLine, contains('Lucknow'));
    });

    test('works without a location fix (match quality only)', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[
          _p('Gomti Nagar Extension', 26.8500, 81.0000),
          _p('Gomti Nagar', 26.8300, 80.9700),
        ],
        'gomti nagar',
        null,
      );
      expect(ranked.first.name, 'Gomti Nagar');
    });

    test('multiple school branches: nearest branch is first, multiple results returned', () {
      // User is at Lucknow center (26.8467, 80.9462)
      // Aliganj is ~4km away, Gomti Nagar is ~5.2km away, Kanpur Road is ~8.8km away
      final Place cmsAliganj = _p('City Montessori School, Aliganj', 26.8833, 80.9412, city: 'Lucknow');
      final Place cmsGomtiNagar = _p('City Montessori School, Gomti Nagar', 26.8488, 80.9982, city: 'Lucknow');
      final Place cmsKanpurRoad = _p('City Montessori School, Kanpur Road', 26.7820, 80.8950, city: 'Lucknow');

      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[cmsKanpurRoad, cmsGomtiNagar, cmsAliganj],
        'city montessori school',
        lucknow,
      );

      // Closest branch must be first
      expect(ranked.first.name, contains('Aliganj'));
      // All branches must be preserved (not truncated to 1)
      expect(ranked.length, 3);
      // Farthest branch must be last
      expect(ranked.last.name, contains('Kanpur Road'));
    });
  });

  group('PlaceRanking — local-first relevance (user-reported bug)', () {
    // The exact fixtures from the bug report: searching "transport" in
    // Lucknow showed "Transport" (Vilhelmina, Sweden) and "Transport Nagar"
    // (Tustin, California) above the traveller's own area.
    final Place vilhelmina = _p('Transport', 63.8541, 12.3973,
        address: 'Vilhelmina', city: 'Vilhelmina', country: 'Sweden');
    final Place tustin = _p('Transport Nagar', 33.7458, -117.8262,
        address: 'Tustin, CA', country: 'United States');
    final Place lucknowTN = _p('Transport Nagar', 26.8000, 80.9000,
        address: 'Lucknow', city: 'Lucknow', country: 'India');

    test('"transport" in Lucknow: Transport Nagar on top, never foreign',
        () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
          <Place>[vilhelmina, tustin, lucknowTN], 'transport', lucknow);
      expect(ranked.first.city, 'Lucknow');
      expect(ranked.first.name, 'Transport Nagar');
    });

    test('"transport nagar" ranks Lucknow first (not exact-match Tustin)',
        () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
          <Place>[tustin, lucknowTN], 'transport nagar', lucknow);
      expect(ranked.first.city, 'Lucknow');
    });

    test('relevance filter hides foreign noise when local results exist',
        () {
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[vilhelmina, tustin, lucknowTN], 'transport', lucknow);
      expect(kept.any((Place p) => p.city == 'Lucknow'), isTrue);
      expect(kept.any((Place p) => p.country == 'Sweden'), isFalse);
      expect(kept.any((Place p) => p.country == 'United States'), isFalse);
    });

    test('explicit city in query keeps the named result even if far', () {
      // Searching "Transport Nagar Lucknow" FROM Delhi: Lucknow is ~425 km
      // away (within 500 km) and the query names it; Tustin is irrelevant.
      final gm.LatLng delhi = const gm.LatLng(28.6139, 77.2090);
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[tustin, lucknowTN], 'transport nagar lucknow', delhi);
      expect(kept.any((Place p) => p.city == 'Lucknow'), isTrue);
      expect(kept.any((Place p) => p.country == 'United States'), isFalse);
    });

    test('no local result + specific far search ("eiffel tower") is kept',
        () {
      final Place eiffel = _p('Eiffel Tower', 48.8584, 2.2945,
          address: 'Paris', city: 'Paris', country: 'France');
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[eiffel], 'eiffel tower', lucknow);
      expect(kept, isNotEmpty);
    });

    test('no local result + generic query → empty ("no relevant nearby")',
        () {
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[vilhelmina], 'transport', lucknow);
      expect(kept, isEmpty);
    });

    test('GPS unavailable: nothing is filtered, text ranking only', () {
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[vilhelmina, tustin], 'transport', null);
      expect(kept.length, 2);
    });

    test('specific query: geocoder fuzzy noise (Nepal / New Delhi) is dropped',
        () {
      // User-reported: "new public college lucknow" from Mau (UP) returned
      // Nepal (347 km), New Delhi (425 km) and नेपाल instead of the college.
      final gm.LatLng mau = const gm.LatLng(26.9742, 82.5244);
      final Place nepal = _p('Nepal', 28.3949, 84.1241,
          address: 'Nepal', country: 'Nepal');
      final Place newDelhi = _p('New Delhi', 28.6519, 77.2315,
          address: 'New Delhi, India', state: 'Delhi', country: 'India');
      final Place nepalDevanagari = _p('नेपाल', 28.3949, 84.1241,
          country: 'Nepal');
      final Place realCollege = _p('New Public College', 26.8467, 80.9462,
          address: 'Near Hazratganj, Lucknow', city: 'Lucknow',
          state: 'Uttar Pradesh', country: 'India');
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[nepal, newDelhi, nepalDevanagari, realCollege],
          'new public college lucknow',
          mau);
      expect(kept.map((Place p) => p.name).toList(),
          <String>['New Public College']);
    });

    test('specific query: a real nearby match with a shared token is kept',
        () {
      final gm.LatLng mau = const gm.LatLng(26.9742, 82.5244);
      final Place publicCollege = _p('Public College', 26.98, 82.53,
          address: 'Mau', city: 'Mau', country: 'India');
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[publicCollege], 'new public college lucknow', mau);
      expect(kept.map((Place p) => p.name).toList(),
          <String>['Public College']);
    });
  });

  group('PlaceRanking — specific-place accuracy (user-reported bug)', () {
    // The biggest complaint: searching for a known place returned a nearby
    // shop with a similar name instead of the actual place.
    final Place tajMahalAgra = _p('Taj Mahal', 27.1751, 78.0421,
        address: 'Dharmapuri, Forest Colony, Agra',
        city: 'Agra', state: 'Uttar Pradesh', country: 'India');
    final Place tajMahalRestaurant = _p('Taj Mahal Restaurant', 26.8500,
        80.9470,
        address: 'Hazratganj, Lucknow', city: 'Lucknow', country: 'India');

    test('"taj mahal" from Lucknow ranks the REAL monument first', () {
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[tajMahalRestaurant, tajMahalAgra],
        'taj mahal',
        lucknow,
      );
      expect(ranked.first.city, 'Agra');
      expect(ranked.first.name, 'Taj Mahal');
    });

    test('"taj mahal" from Lucknow keeps the monument in the relevant set',
        () {
      final List<Place> kept = PlaceRanking.filterRelevant(
        <Place>[tajMahalRestaurant, tajMahalAgra],
        'taj mahal',
        lucknow,
      );
      expect(kept.any((Place p) => p.city == 'Agra'), isTrue);
      expect(kept.any((Place p) => p.city == 'Lucknow'), isTrue);
    });

    test('single-token generic query: exact far name still loses to local',
        () {
      // "transport" must not put Vilhelmina's exact "Transport" above the
      // local Transport Nagar — only SPECIFIC multi-word queries get the
      // far-exact promotion.
      final Place exactFar = _p('Transport', 63.8541, 12.3973,
          address: 'Vilhelmina', country: 'Sweden');
      final Place boundaryNear = _p('Transport Nagar', 26.8000, 80.9000,
          address: 'Lucknow', city: 'Lucknow', country: 'India');
      final List<Place> ranked = PlaceRanking.rankSuggestions(
        <Place>[exactFar, boundaryNear],
        'transport',
        lucknow,
      );
      expect(ranked.first.city, 'Lucknow');
    });

    test('exact name matching ignores case and punctuation', () {
      expect(
        PlaceRanking.isExactNameMatch(tajMahalAgra, '  Taj  Mahal! '),
        isTrue,
      );
      expect(
        PlaceRanking.isExactNameMatch(tajMahalRestaurant, 'taj mahal'),
        isFalse,
      );
    });

    test('strong match keeps full-prefix places, not random ones', () {
      final Place garden = _p('Taj Mahal Garden', 27.1751, 78.0421);
      final Place cafe = _p('Cafe Taj', 26.8500, 80.9470);
      expect(PlaceRanking.isStrongNameMatch(garden, 'taj mahal'), isTrue);
      expect(PlaceRanking.isStrongNameMatch(cafe, 'taj mahal'), isFalse);
      // Single-token queries are only "strong" on an exact name.
      expect(PlaceRanking.isStrongNameMatch(garden, 'taj'), isFalse);
      expect(PlaceRanking.isStrongNameMatch(tajMahalAgra, 'taj'), isFalse);
      expect(
        PlaceRanking.isStrongNameMatch(_p('Taj', 26.85, 80.94), 'taj'),
        isTrue,
      );
    });
  });
}
