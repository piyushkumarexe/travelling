import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:tourism/core/network/api_client.dart';
import 'package:tourism/core/network/api_exception.dart';
import 'package:tourism/core/network/free_geo_client.dart';
import 'package:tourism/data/models/weather.dart';
import 'package:tourism/data/repositories/weather_repository.dart';

void main() {
  test('weather uses real fallback when the backend provider fails', () async {
    final _FakeFreeGeoClient free = _FakeFreeGeoClient();
    final WeatherRepository repository = WeatherRepository(
      _UnavailableApi(),
      free: free,
    );
    const LatLng location = LatLng(26.8467, 80.9462);

    final WeatherCurrent current = await repository.current(location);
    final List<ForecastDay> forecast = await repository.forecast(location);

    expect(current.tempC, 29.5);
    expect(current.condition, 'Clear sky');
    expect(forecast, hasLength(1));
    expect(forecast.single.tempMaxC, 32);
    expect(free.currentCalls, 1);
    expect(free.forecastCalls, 1);
  });
}

class _UnavailableApi extends ApiClient {
  _UnavailableApi() : super(baseUrl: 'https://backend.invalid');

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    Duration? receiveTimeout,
  }) async {
    throw ApiException(
      ApiErrorKind.upstream,
      'Provider unavailable',
      statusCode: 502,
    );
  }
}

class _FakeFreeGeoClient extends FreeGeoClient {
  int currentCalls = 0;
  int forecastCalls = 0;

  @override
  Future<WeatherCurrent> weather(double lat, double lng) async {
    currentCalls += 1;
    return WeatherCurrent.fromJson(<String, dynamic>{
      'tempC': 29.5,
      'feelsLikeC': 30,
      'humidityPct': 55,
      'windMs': 2,
      'windDeg': 90,
      'condition': 'Clear sky',
      'icon': '01d',
      'pressureHpa': 1005,
      'visibilityM': 10000,
      'updatedAt': '2026-10-28T12:00:00.000Z',
    });
  }

  @override
  Future<List<ForecastDay>> forecast(double lat, double lng) async {
    forecastCalls += 1;
    return <ForecastDay>[
      ForecastDay.fromJson(<String, dynamic>{
        'date': '2026-10-29T12:00:00.000Z',
        'tempMaxC': 32,
        'tempMinC': 22,
        'condition': 'Clear sky',
        'icon': '01d',
        'precipChancePct': 0,
      }),
    ];
  }
}
