import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/free_geo_client.dart';
import '../models/weather.dart';

/// Weather through the Tourism backend (OpenWeather, server-side key) with a
/// real free fallback (Open-Meteo, no key) so weather works even before the
/// backend is deployed.
class WeatherRepository {
  WeatherRepository(this._api);

  final ApiClient _api;
  final FreeGeoClient _free = FreeGeoClient();

  Future<WeatherCurrent> current(LatLng location) async {
    try {
      final Map<String, dynamic> data =
          await _api.post('/weatherCurrent', <String, dynamic>{
        'lat': location.latitude,
        'lng': location.longitude,
      });
      final dynamic c = data['current'];
      if (c is Map<String, dynamic>) return WeatherCurrent.fromJson(c);
      throw ApiException(ApiErrorKind.upstream,
          'The weather service returned no data for this location.');
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.upstream) rethrow;
      return _free.weather(location.latitude, location.longitude);
    }
  }

  Future<List<ForecastDay>> forecast(LatLng location) async {
    try {
      final Map<String, dynamic> data =
          await _api.post('/weatherForecast', <String, dynamic>{
        'lat': location.latitude,
        'lng': location.longitude,
      });
      final List<dynamic> raw =
          (data['days'] is List) ? data['days'] as List : <dynamic>[];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(ForecastDay.fromJson)
          .toList();
    } on ApiException {
      return _free.forecast(location.latitude, location.longitude);
    }
  }
}
