import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../models/weather.dart';

/// OpenWeather data through the Roamio backend (key stays server-side).
class WeatherRepository {
  WeatherRepository(this._api);

  final ApiClient _api;

  Future<WeatherCurrent> current(LatLng location) async {
    final Map<String, dynamic> data =
        await _api.post('/weatherCurrent', <String, dynamic>{
      'lat': location.latitude,
      'lng': location.longitude,
    });
    final dynamic c = data['current'];
    if (c is Map<String, dynamic>) return WeatherCurrent.fromJson(c);
    throw ApiException(ApiErrorKind.upstream,
        'The weather service returned no data for this location.');
  }

  Future<List<ForecastDay>> forecast(LatLng location) async {
    final Map<String, dynamic> data =
        await _api.post('/weatherForecast', <String, dynamic>{
      'lat': location.latitude,
      'lng': location.longitude,
    });
    final List<dynamic> raw = (data['days'] is List) ? data['days'] as List : <dynamic>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ForecastDay.fromJson)
        .toList();
  }
}
