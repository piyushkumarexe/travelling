import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:yatrawise/core/network/api_exception.dart';
import 'package:yatrawise/data/local/nearby_store.dart';
import 'package:yatrawise/data/models/places.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forced refresh preserves a real cached dataset on provider failure',
      () async {
    final NearbyStore store = NearbyStore();
    const LatLng here = LatLng(26.8467, 80.9462);
    final Place station = Place(
      placeId: 'station-1',
      name: 'Test Station',
      lat: 26.8470,
      lng: 80.9465,
      category: 'transit',
      provider: 'overpass',
    );

    final NearbyResult first = await store.load(
      here,
      variant: 'category:transit|r:25000',
      fetch: () async => <Place>[station],
    );
    expect(first.places, hasLength(1));
    expect(first.fromCache, isFalse);

    final NearbyResult rescued = await store.load(
      here,
      force: true,
      variant: 'category:transit|r:25000',
      fetch: () async => throw const ApiException(
        ApiErrorKind.network,
        'provider unavailable',
      ),
    );
    expect(rescued.places.single.name, 'Test Station');
    expect(rescued.fromCache, isTrue);
    expect(rescued.stale, isTrue);

  });
}
