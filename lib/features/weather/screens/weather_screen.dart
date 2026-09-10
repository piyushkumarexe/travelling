import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/weather.dart';

/// Live weather (OpenWeather via the Roamio backend) with practical
/// safety notes and a 5-day forecast for the current location.
class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  AppContainer get _c => AppScope.of(context);

  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _locationLabel;
  WeatherCurrent? _current;
  List<ForecastDay> _forecast = const <ForecastDay>[];

  Future<void> _load({bool refresh = false}) async {
    if (refresh) {
      if (mounted) setState(() => _refreshing = true);
    } else {
      if (mounted) {
        setState(() {
          _loading = true;
          _error = null;
        });
      }
    }
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (pos == null) {
        throw Exception('Location unavailable. Enable GPS and retry.');
      }
      final LatLng ll = LatLng(pos.latitude, pos.longitude);
      final WeatherCurrent current = await _c.weatherRepository.current(ll);
      final List<ForecastDay> forecast =
          await _c.weatherRepository.forecast(ll);
      String? label;
      try {
        label = await _c.placesRepository.reverseGeocode(ll);
      } catch (_) {
        label = null;
      }
      if (!mounted) return;
      setState(() {
        _current = current;
        _forecast = forecast;
        _locationLabel = label;
        _loading = false;
        _error = null;
        _refreshing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = e.toString();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _compass(double deg) {
    const List<String> dirs = <String>[
      'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'
    ];
    final int idx = ((deg + 22.5) / 45).floor() % 8;
    return dirs[idx];
  }

  IconData _fallbackIcon(String icon) {
    if (icon.startsWith('09') || icon.startsWith('10')) return Icons.grain;
    if (icon.startsWith('50')) return Icons.foggy;
    if (icon.startsWith('71') ||
        icon.startsWith('72') ||
        icon.startsWith('73')) {
      return Icons.ac_unit;
    }
    if (icon.startsWith('74') ||
        icon.startsWith('75') ||
        icon.startsWith('76') ||
        icon.startsWith('77') ||
        icon.startsWith('80')) {
      return Icons.bolt;
    }
    if (icon.startsWith('02') ||
        icon.startsWith('03') ||
        icon.startsWith('04')) {
      return Icons.cloud;
    }
    return Icons.wb_sunny;
  }

  /// Real OpenWeather icon artwork; falls back to a Material icon while
  /// loading or when the network is unavailable.
  Widget _weatherIcon(String icon, double size, Color color) {
    final Widget fallback =
        Icon(_fallbackIcon(icon), size: size, color: color);
    return Image.network(
      'https://openweathermap.org/img/wn/${icon}@2x.png',
      width: size,
      height: size,
      loadingBuilder: (BuildContext context, Widget child,
          ImageChunkEvent? _) =>
          fallback,
      errorBuilder: (BuildContext context, Object e, StackTrace? s) =>
          fallback,
    );
  }

  String _dayName(DateTime d) {
    final DateTime now = DateTime.now();
    if (d.day == now.day && d.month == now.month && d.year == now.year) {
      return 'Today';
    }
    final DateTime tomorrow = now.add(const Duration(days: 1));
    if (d.day == tomorrow.day &&
        d.month == tomorrow.month &&
        d.year == tomorrow.year) {
      return 'Tomorrow';
    }
    return Fmt.weekday(d);
  }

  String _visibility(double meters) {
    if (meters <= 0) return 'n/a';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Weather'),
        actions: <Widget>[
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed:
                _refreshing || _loading ? null : () => _load(refresh: true),
          ),
        ],
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  SkeletonCard(height: 260),
                  SizedBox(height: 12),
                  SkeletonCard(height: 120),
                  SizedBox(height: 12),
                  SkeletonList(count: 4, height: 72),
                ],
              ),
            )
          : _error != null
              ? ErrorState(message: _error!, onRetry: () => _load())
              : _current == null
                  ? const LoadingView(message: 'Loading weather…')
                  : RefreshIndicator(
                      onRefresh: () => _load(refresh: true),
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: <Widget>[
                          _currentCard(scheme),
                          const SizedBox(height: 12),
                          _notesCard(scheme),
                          const SizedBox(height: 16),
                          Text(
                            '5-day forecast',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 10),
                          if (_forecast.isEmpty)
                            AppCard(
                              child: Text(
                                'Forecast is not available for this location.',
                                style: Theme.of(context).textTheme.bodySmall,
                                textAlign: TextAlign.center,
                              ),
                            )
                          else
                            Column(
                              children: <Widget>[
                                for (final ForecastDay d in _forecast)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: AppCard(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 10),
                                      child: Row(
                                        children: <Widget>[
                                          _weatherIcon(d.icon, 32,
                                              scheme.onSurfaceVariant),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: <Widget>[
                                                Text(
                                                  _dayName(d.date),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w700),
                                                ),
                                                Text(
                                                  d.condition,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall,
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (d.precipChancePct > 0)
                                            Padding(
                                              padding: const EdgeInsets
                                                  .only(right: 10),
                                              child: Row(
                                                children: <Widget>[
                                                  const Icon(Icons.water_drop,
                                                      size: 14,
                                                      color:
                                                          Colors.lightBlue),
                                                  const SizedBox(width: 2),
                                                  Text(
                                                    '${d.precipChancePct}%',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          Text(
                                            '${d.tempMaxC.round()}°',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall
                                                ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.w800),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '${d.tempMinC.round()}°',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                    color:
                                                        scheme.onSurfaceVariant),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
    );
  }

  Widget _currentCard(ColorScheme scheme) {
    final WeatherCurrent w = _current!;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF0B3954), Color(0xFF0E7C7B)],
        ),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      child: Column(
        children: <Widget>[
          if (_locationLabel != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.place, color: Colors.white70, size: 16),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _locationLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.85), fontSize: 13),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 14),
          _weatherIcon(w.icon, 84, Colors.white),
          const SizedBox(height: 10),
          Text(
            '${w.tempC.round()}°C',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 52,
                fontWeight: FontWeight.w800),
          ),
          Text(
            w.condition,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Feels like ${w.feelsLikeC.round()}°C · Updated ${Fmt.time(w.updatedAt)}',
            style: TextStyle(
                color: Colors.white.withOpacity(0.75), fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                  child:
                      _metric(Icons.water_drop, 'Humidity', '${w.humidityPct}%')),
              Expanded(
                  child: _metric(
                      Icons.air,
                      'Wind',
                      '${(w.windMs * 3.6).round()} km/h ${_compass(w.windDeg)}')),
              Expanded(
                  child: _metric(
                      Icons.speed, 'Pressure', '${w.pressureHpa} hPa')),
              Expanded(
                  child: _metric(
                      Icons.visibility, 'Visibility', _visibility(w.visibilityM))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, color: Colors.white70, size: 18),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 11),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _notesCard(ColorScheme scheme) {
    final WeatherCurrent w = _current!;
    final List<String> notes = weatherSafetyNotes(w);
    final bool hasAlert = !(notes.isNotEmpty &&
        notes.first.contains('comfortable'));
    return AppCard(
      color: hasAlert
          ? AppTheme.warning.withOpacity(0.08)
          : AppTheme.success.withOpacity(0.06),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                hasAlert ? Icons.warning_amber : Icons.beach_access,
                color: hasAlert ? AppTheme.warning : AppTheme.success,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Weather safety notes',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final String note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: Icon(Icons.circle,
                        size: 6, color: AppTheme.warning),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child:
                        Text(note, style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
