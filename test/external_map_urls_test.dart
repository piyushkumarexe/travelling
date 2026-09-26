import 'package:flutter_test/flutter_test.dart';
import 'package:yatrawise/core/utils/external_map_urls.dart';

void main() {
  group('ExternalMapUrls', () {
    test('builds a close tilted Google Earth camera URL', () {
      final Uri uri = ExternalMapUrls.googleEarth3d(
        latitude: 26.8467,
        longitude: 80.9462,
      );

      expect(uri.scheme, 'https');
      expect(uri.host, 'earth.google.com');
      expect(uri.path, contains('@26.846700,80.946200'));
      expect(uri.path, endsWith('150a,1200d,35y,0h,60t,0r'));
    });

    test('builds a coordinate-based Google Maps fallback', () {
      final Uri uri = ExternalMapUrls.googleMapsPlace(
        latitude: 19.076,
        longitude: 72.8777,
      );

      expect(uri.host, 'www.google.com');
      expect(uri.queryParameters['api'], '1');
      expect(uri.queryParameters['query'], '19.076000,72.877700');
    });

    test('rejects invalid coordinates before launching', () {
      expect(
        () => ExternalMapUrls.googleEarth3d(
          latitude: 91,
          longitude: 80,
        ),
        throwsArgumentError,
      );
      expect(
        () => ExternalMapUrls.googleMapsPlace(
          latitude: 20,
          longitude: double.nan,
        ),
        throwsArgumentError,
      );
    });
  });
}
