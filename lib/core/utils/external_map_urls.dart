/// URLs for handing a location to specialised external map applications.
///
/// Tourism deliberately does not proxy, scrape, or cache Google imagery.
/// Opening the provider's own application is the legal, no-billing way to let
/// a traveller inspect the provider's available photorealistic 3D coverage.
abstract final class ExternalMapUrls {
  static Uri googleEarth3d({
    required double latitude,
    required double longitude,
  }) {
    _validateCoordinate(latitude, longitude);

    // Earth web links are also Android app links. On devices with Google Earth
    // installed Android opens the app; otherwise the browser shows Google's
    // supported Earth experience/install path. A close, tilted camera makes
    // available photogrammetry visible immediately.
    return Uri.parse(
      'https://earth.google.com/web/@'
      '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)},'
      '150a,1200d,35y,0h,60t,0r',
    );
  }

  static Uri googleMapsPlace({
    required double latitude,
    required double longitude,
  }) {
    _validateCoordinate(latitude, longitude);
    return Uri.https('www.google.com', '/maps/search/', <String, String>{
      'api': '1',
      'query': '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}',
    });
  }

  static void _validateCoordinate(double latitude, double longitude) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw ArgumentError('Invalid map coordinate: $latitude, $longitude');
    }
  }
}
