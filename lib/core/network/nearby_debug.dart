/// TEMPORARY developer-facing diagnostics for the nearby (Overpass) flow.
///
/// Populated by `FreeGeoClient._overpassElements` / `_nearbyCategories` and
/// read by the Explore screen so the ACTUAL runtime result can be seen
/// on-device (HTTP status, raw/parsed/final counts, error). Never holds an
/// API key. Remove the Explore-side rendering once the nearby flow is
/// verified on a physical device.
class NearbyDebug {
  NearbyDebug._();

  static final NearbyDebug instance = NearbyDebug._();

  String phase = 'idle';
  String? location;
  String? host;
  int? httpStatus;
  int? responseBytes;
  int? rawCount;
  int? parsedCount;
  int? finalCount;
  String? error;
  int requestCount = 0;
  int okQueries = 0;
  int failQueries = 0;

  void reset({String phase = 'idle', String? location}) {
    this.phase = phase;
    if (location != null) this.location = location;
    host = null;
    httpStatus = null;
    responseBytes = null;
    rawCount = null;
    parsedCount = null;
    finalCount = null;
    error = null;
    okQueries = 0;
    failQueries = 0;
  }

  String get summary {
    final StringBuffer b = StringBuffer();
    b.writeln('phase: $phase');
    if (location != null) b.writeln('location: $location');
    b.writeln('host: ${host ?? '-'}');
    b.writeln('HTTP: ${httpStatus?.toString() ?? '-'}');
    b.writeln('Raw: ${rawCount?.toString() ?? '-'}');
    b.writeln('Parsed: ${parsedCount?.toString() ?? '-'}');
    b.writeln('Final: ${finalCount?.toString() ?? '-'}');
    b.writeln('error: ${error ?? '-'}');
    return b.toString().trimRight();
  }
}
