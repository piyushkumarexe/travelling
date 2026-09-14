import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:yatrawise/core/network/free_geo_client.dart';
import 'package:yatrawise/data/models/places.dart';

Place _p(String name, double lat, double lng, {String? address}) => Place(
      placeId: 'test-$name-$lat,$lng',
      name: name,
      lat: lat,
      lng: lng,
      address: address,
      primaryType: 'place',
      types: const <String>['point_of_interest'],
      provider: 'test',
    );

void main() {
  // Lucknow city centre (the traveller's area in the reported bug).
  final LatLng lucknow = const LatLng(26.8467, 80.9462);

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
  });
}
