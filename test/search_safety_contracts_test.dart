import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;

import 'package:yatrawise/core/network/free_geo_client.dart';
import 'package:yatrawise/data/models/incident.dart';
import 'package:yatrawise/data/models/places.dart';

/// Locks the two behaviour contracts behind the 2026-09 search/safety fixes:
///  * a CATEGORY query must never be filtered down to nothing by name
///    relevance ("tourist attractions" in a city of 4 million used to answer
///    "No places found nearby"), while a specific place-name query must still
///    drop geocoder noise from other states;
///  * `Incident.toMap()` must write the exact document shape that
///    `firestore/rules` validates — the rules reference `location.lat/lng`,
///    and a missing field there means Firestore denies the write.
Place _place(String name, double lat, double lng, {String? city}) => Place(
      placeId: 'test-$name-$lat',
      name: name,
      lat: lat,
      lng: lng,
      city: city,
    );

const gm.LatLng _lucknow = gm.LatLng(26.8467, 80.9462);

void main() {
  group('category vs named queries', () {
    test('category words are recognised without a name match', () {
      final FreeGeoClient geo = FreeGeoClient();
      expect(geo.isCategoryQuery('tourist attractions near me'), isTrue);
      expect(geo.isCategoryQuery('best cafes'), isTrue);
      expect(geo.isCategoryQuery('hospital'), isTrue);
      // A specific monument is NOT a category: the real one is 300 km away
      // and the traveller still wants it.
      expect(geo.isCategoryQuery('taj mahal'), isFalse);
      expect(geo.isCategoryQuery('ambedkar memorial lucknow'), isFalse);
      expect(geo.isCategoryQuery(''), isFalse);
    });

    test('every category word is stripped before a name is required', () {
      // kCategoryWords is what makes the above safe: adding a category word
      // here must never require it to appear in a result name.
      expect(PlaceRanking.kCategoryWords, contains('attractions'));
      expect(PlaceRanking.kCategoryWords, contains('tourist'));
      expect(PlaceRanking.kCategoryWords, contains('near'));
      expect(PlaceRanking.kCategoryWords.contains('taj'), isFalse);
    });

    test('a pure category query keeps real nearby places that do not match',
        () {
      final List<Place> found = <Place>[
        _place('Bara Imambara', 26.8536, 80.9499),
        _place('Chhota Imambara', 26.8530, 80.9521),
        _place('Constantine Hall', 26.8690, 80.9380),
      ];
      final List<Place> kept = PlaceRanking.filterRelevant(
          found, 'tourist attractions near me', _lucknow);
      expect(kept.length, found.length,
          reason: 'none of these is literally named "attraction", yet all are '
              'real nearby results for a category query');
    });

    test('a specific named query still drops 400 km geocoder noise', () {
      // None of these results lies in the searched city, and the query names
      // neither their locality nor their exact place — they used to be served
      // as answers to a college search in Lucknow.
      final List<Place> found = <Place>[
        _place('New public college', 26.8700, 80.9400, city: 'Lucknow'),
        _place('Delhi Ridge', 28.6139, 77.2090, city: 'Delhi'),
        _place('Sector 18 Market', 28.5355, 77.3910, city: 'Noida'),
      ];
      final List<Place> kept = PlaceRanking.filterRelevant(
          found, 'new public college', _lucknow);
      expect(kept.map((Place p) => p.name).toList(),
          <String>['New public college']);
    });

    test('a far place the query explicitly names is kept', () {
      // Distance never overrides intent: "taj mahal agra" from Lucknow must
      // show the monument, not an empty list.
      final List<Place> found = <Place>[
        _place('Taj Mahal', 27.1751, 78.0421, city: 'Agra'),
      ];
      final List<Place> kept =
          PlaceRanking.filterRelevant(found, 'taj mahal agra', _lucknow);
      expect(kept.map((Place p) => p.name).toList(), <String>['Taj Mahal']);
    });

    test('without an origin nothing is filtered out', () {
      final List<Place> found = <Place>[
        _place('Taj Mahal', 27.1751, 78.0421, city: 'Agra'),
      ];
      expect(PlaceRanking.filterRelevant(found, 'x y z', null), found);
    });
  });

  group('the relevance rule is one rule (map search reported bug)', () {
    // MapScreen re-checks the rows PlacesRepository returns, so the two must
    // share `nameMatchesQuery` — a second, slightly different copy of the
    // token rule is how "new public college" kept showing Noida.
    test('a name match needs a real word, not a 3-letter fragment', () {
      final Place college = Place(
        placeId: 'osm-1',
        name: 'New Public College',
        lat: 26.8700,
        lng: 80.9400,
        address: 'Ashok Marg, Lucknow',
        city: 'Lucknow',
        primaryType: 'college',
        types: const <String>['college'],
      );
      final Place noida = Place(
        placeId: 'osm-2',
        name: 'Noida',
        lat: 28.5355,
        lng: 77.3910,
        address: 'Noida, Uttar Pradesh, India',
        city: 'New Delhi',
        state: 'Uttar Pradesh',
        primaryType: 'city',
        types: const <String>['administrative_area'],
      );
      expect(PlaceRanking.nameMatchesQuery(college, 'new Public college'),
          isTrue);
      expect(PlaceRanking.nameMatchesQuery(noida, 'new Public college'), isFalse,
          reason: '"new" is 3 letters — it must never vouch for New Delhi');
      expect(PlaceRanking.nameMatchesQuery(noida, 'noida'), isTrue,
          reason: 'searching for the city itself must still find the city');
    });

    test('a category query accepts results that do not carry the word', () {
      final Place cafe = Place(
        placeId: 'osm-3',
        name: 'Sahu Chai Corner',
        lat: 26.8500,
        lng: 80.9410,
        primaryType: 'cafe',
        types: const <String>['cafe'],
      );
      expect(PlaceRanking.nameMatchesQuery(cafe, 'cafes near me'), isTrue,
          reason: '"cafe" and "near me" are category words, not a name');
    });

    test('an address alone no longer makes a place "explicitly located"', () {
      // The old rule matched the query against the free-form address too, so
      // any college whose address sat in New Delhi was accepted for "new
      // public college". Only the administrative fields may vouch now.
      final Place delhiCollege = Place(
        placeId: 'osm-4',
        name: 'Holy Child School',
        lat: 28.6100,
        lng: 77.2100,
        address: 'New Delhi, Delhi, India',
        city: 'Delhi',
        primaryType: 'school',
        types: const <String>['school'],
      );
      expect(
          PlaceRanking.queryNamesLocality(
              delhiCollege, PlaceRanking.normalizeName('new public college')),
          isFalse);
      expect(
          PlaceRanking.queryNamesLocality(
              delhiCollege, PlaceRanking.normalizeName('school new delhi')),
          isTrue,
          reason: 'naming the city in the query must still work');
    });
  });

  group('admin regions are not answers (map search reported bug)', () {
    // Typing "new Public college" into the Map tab offered "Noida — Noida,
    // Ut…" as the only result: a 470 km-away CITY, because the geocoders
    // return city records too and nothing said a city is not a venue.
    Place noidaNominatimStyle() => Place(
          placeId: 'nom-123',
          name: 'Noida',
          lat: 28.5355,
          lng: 77.3910,
          address: 'Noida, Uttar Pradesh, India',
          primaryType: 'city',
          types: const <String>['administrative_area', 'political'],
          city: 'Noida',
          state: 'Uttar Pradesh',
        );

    test('a city record is recognised as an administrative region', () {
      expect(PlaceRanking.isAdminRegion(noidaNominatimStyle()), isTrue);
      expect(PlaceRanking.isAdminType('suburb'), isTrue);
      expect(PlaceRanking.isAdminType('administrative_area_level_2'), isTrue);
      expect(PlaceRanking.isAdminType('college'), isFalse);
      expect(PlaceRanking.isAdminType('tourist_attraction'), isFalse);
      expect(PlaceRanking.isAdminType('point_of_interest'), isFalse);
    });

    test('a specific place query never resolves to a far city', () {
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[noidaNominatimStyle()], 'new Public college', _lucknow);
      expect(kept, isEmpty,
          reason: 'the city of Noida is not a college; the honest answer is '
              'no result, not admin noise 470 km away');
    });

    test('a real venue with the same locality stays', () {
      final Place college = Place(
        placeId: 'ph-9',
        name: 'New Public College',
        lat: 26.8692,
        lng: 80.9401,
        primaryType: 'college',
        types: const <String>['point_of_interest'],
        city: 'Lucknow',
        state: 'Uttar Pradesh',
      );
      expect(PlaceRanking.isAdminRegion(college), isFalse);
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[college, noidaNominatimStyle()], 'new Public college',
          _lucknow);
      expect(kept.map((Place p) => p.placeId).toList(), <String>['ph-9']);
    });

    test('a query that names the city still gets the city', () {
      // "noida" is a legitimate search for the place itself.
      final List<Place> kept = PlaceRanking.filterRelevant(
          <Place>[noidaNominatimStyle()], 'noida', _lucknow);
      expect(kept.length, 1);
    });
  });

  group('incident document shape (firestore.rules contract)', () {
    Incident build({String description = 'Wallet stolen in the bus station'}) =>
        Incident(
          id: 'i1',
          uid: 'u1',
          reporterName: 'Piyush',
          description: description,
          category: 'theft',
          severity: 'high',
          status: 'reported',
          lat: 26.8467,
          lng: 80.9462,
          createdAt: DateTime.utc(2026, 9, 20, 6, 30),
        );

    test('coordinates are nested under location, not top level', () {
      final Map<String, dynamic> m = build().toMap();
      expect(m.containsKey('location'), isTrue);
      final Map<String, double> loc = m['location'] as Map<String, double>;
      expect(loc['lat'], 26.8467);
      expect(loc['lng'], 80.9462);
      // The rules validate `location.lat` — and they used to validate a
      // top-level `lat`, which does not exist in this document.
      expect(m.containsKey('lat'), isFalse);
      expect(m.containsKey('lng'), isFalse);
    });

    test('fields the rules constrain carry allowed values', () {
      final Map<String, dynamic> m = build().toMap();
      expect(m['status'], 'reported'); // create requires exactly this
      expect(m['uid'], 'u1'); // must equal request.auth.uid
      expect(<String>['low', 'medium', 'high', 'critical'], contains(m['severity']));
      expect(
          <String>[
            'theft', 'fraud', 'assault', 'harassment', 'accident',
            'unsafe_area', 'poor_infrastructure', 'natural_hazard', 'other'
          ],
          contains(m['category']));
      final String description = m['description'] as String;
      expect(description.length, greaterThanOrEqualTo(10));
      expect(description.length, lessThanOrEqualTo(2000));
      expect((m['reporterName'] as String).length, lessThanOrEqualTo(120));
    });

    test('a short description is rejected before the write, not by rules', () {
      // The report sheet relies on this so a user is never told "permission
      // denied" for typing one word.
      expect(build(description: 'help').description.length, lessThan(10));
    });

    test('fromMap reads the nested coordinates back', () {
      final Map<String, dynamic> m = build().toMap()
        ..remove('createdAt')
        ..remove('updatedAt');
      final Incident round = Incident.fromMap('i1', m);
      expect(round.lat, 26.8467);
      expect(round.lng, 80.9462);
      expect(round.category, 'theft');
      expect(round.severityLabel, 'High');
      expect(round.statusLabel, 'Reported');
    });
  });
}
