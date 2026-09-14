// 🗺️ 3D navigation map for Live Trip — MapLibre GL with camera tilt
// (true perspective view), heading-up bearing and speed-adaptive zoom, plus
// 3D building extrusions from MapTiler's v3 vector tileset.
//
// Reuses the SAME MapTiler key/config as the 2D map (AppConfig). Needs a
// key because vector styles are MapTiler-hosted; without one the parent
// screen keeps the working 2D map (never a blank screen).

import 'dart:async' show Completer, unawaited;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../../../core/app_config.dart';

class NavMap3D extends StatefulWidget {
  const NavMap3D({
    super.key,
    required this.position,
    required this.routeLine,
    required this.destination,
    required this.follow,
    required this.satellite,
    required this.onUnavailable,
  });

  /// Latest device fix from the existing location stream.
  final Position? position;
  final List<ll.LatLng> routeLine;
  final ll.LatLng? destination;

  /// Google-style follow camera (bearing = travel direction + tilt).
  final bool follow;

  /// Reuses the Live Trip satellite toggle (hybrid imagery vs streets).
  final bool satellite;

  /// Called when the 3D view cannot render (no MapTiler key / style
  /// failure) so the parent can fall back to the 2D map.
  final VoidCallback onUnavailable;

  @override
  State<NavMap3D> createState() => _NavMap3DState();
}

class _NavMap3DState extends State<NavMap3D> {
  ml.MapLibreMapController? _controller;
  final Completer<void> _styleReady = Completer<void>();
  bool _failed = false;
  double _lastBearing = 0;
  double _lastZoom = 16.5;
  List<ll.LatLng> _lastRoute = const <ll.LatLng>[];
  ll.LatLng? _lastDest;

  static const double _tilt = 47.5;

  String? get _styleUrl =>
      AppConfig.styleJsonUrl(widget.satellite ? 'hybrid' : 'streets-v2');

  @override
  void initState() {
    super.initState();
    if (_styleUrl == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onUnavailable();
      });
    }
  }

  // ---------------- camera ----------------

  double _zoomForSpeed(double kmh) {
    if (kmh >= 80) return 15.5;
    if (kmh >= 45) return 16.5;
    return 17.0;
  }

  Future<void> _updateCamera() async {
    final ml.MapLibreMapController? c = _controller;
    final Position? p = widget.position;
    if (c == null || p == null || !widget.follow || !mounted) return;
    if (!_styleReady.isCompleted) return;
    final double kmh = (p.speed < 0 ? 0 : p.speed) * 3.6;
    final bool headingValid =
        !p.heading.isNaN && p.heading >= 0 && p.heading <= 360;
    final double bearing =
        headingValid ? p.heading : _lastBearing;
    final double zoom = _zoomForSpeed(kmh);
    // Skip micro-updates so the camera does not jitter every tick.
    final double dBearing = (bearing - _lastBearing).abs() % 360;
    if ((p.latitude * 1e5).round() == (_lastLat * 1e5).round() &&
        (p.longitude * 1e5).round() == (_lastLng * 1e5).round() &&
        (zoom - _lastZoom).abs() < 0.01 &&
        (dBearing < 4 || dBearing > 356)) {
      return;
    }
    _lastBearing = bearing;
    _lastZoom = zoom;
    _lastLat = p.latitude;
    _lastLng = p.longitude;
    try {
      await c.animateCamera(
        ml.CameraUpdate.newCameraPosition(
          ml.CameraPosition(
            target: ml.LatLng(p.latitude, p.longitude),
            zoom: zoom,
            bearing: bearing,
            tilt: _tilt,
          ),
        ),
        duration: const Duration(milliseconds: 350),
      );
    } catch (_) {
      // Camera races during style load are harmless.
    }
  }

  double _lastLat = 0;
  double _lastLng = 0;

  // ---------------- layers ----------------

  Map<String, dynamic> _routeGeoJson() {
    final List<List<double>> coords = <List<double>>[
      for (final ll.LatLng p in widget.routeLine) <double>[p.longitude, p.latitude],
    ];
    return <String, dynamic>{
      'type': 'FeatureCollection',
      'features': <Map<String, dynamic>>[
        if (coords.length >= 2)
          <String, dynamic>{
            'type': 'Feature',
            'properties': <String, dynamic>{},
            'geometry': <String, dynamic>{
              'type': 'LineString',
              'coordinates': coords,
            },
          },
      ],
    };
  }

  Map<String, dynamic> _destGeoJson() {
    final ll.LatLng? d = widget.destination;
    return <String, dynamic>{
      'type': 'FeatureCollection',
      'features': <Map<String, dynamic>>[
        if (d != null)
          <String, dynamic>{
            'type': 'Feature',
            'properties': <String, dynamic>{},
            'geometry': <String, dynamic>{
              'type': 'Point',
              'coordinates': <double>[d.longitude, d.latitude],
            },
          },
      ],
    };
  }

  Future<void> _buildLayers() async {
    final ml.MapLibreMapController c = _controller!;
    // Route casing + line.
    await c.addGeoJsonSource('nav_route_src', _routeGeoJson());
    await c.addLineLayer(
      'nav_route_src',
      'nav_route_casing',
      ml.LineLayerProperties(
        lineColor: '#FFFFFF',
        lineWidth: 9,
        lineJoin: 'round',
        lineCap: 'round',
      ),
    );
    await c.addLineLayer(
      'nav_route_src',
      'nav_route_line',
      ml.LineLayerProperties(
        lineColor: '#2563EB',
        lineWidth: 6,
        lineJoin: 'round',
        lineCap: 'round',
      ),
    );
    // Destination dot.
    await c.addGeoJsonSource('nav_dest_src', _destGeoJson());
    await c.addCircleLayer(
      'nav_dest_src',
      'nav_dest_pin',
      ml.CircleLayerProperties(
        circleRadius: 9,
        circleColor: '#DC2626',
        circleStrokeWidth: 3,
        circleStrokeColor: '#FFFFFF',
      ),
    );
    // 3D buildings (optional — silently skipped if the vector source or
    // `building` layer is unavailable).
    final String? tilesJson = AppConfig.vectorTilesJsonUrl;
    if (tilesJson != null) {
      await c.addSource(
        'nav_buildings_src',
        ml.VectorSourceProperties(url: tilesJson),
      );
      await c.addFillExtrusionLayer(
        'nav_buildings_src',
        'nav_buildings_3d',
        ml.FillExtrusionLayerProperties(
          fillExtrusionColor: '#9CA3AF',
          fillExtrusionHeight: <dynamic>['coalesce', <dynamic>['get', 'render_height'], 8.0],
          fillExtrusionBase: <dynamic>['coalesce', <dynamic>['get', 'render_min_height'], 0.0],
          fillExtrusionOpacity: 0.75,
        ),
        sourceLayer: 'building',
      );
    }
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    final String? styleUrl = _styleUrl;
    if (styleUrl == null) {
      return const ColoredBox(
        color: Color(0xFF101418),
        child: Center(
          child: Text('3D map needs the map style key — using 2D instead.',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
        ),
      );
    }
    final Position? p = widget.position;
    final ll.LatLng center = p != null
        ? ll.LatLng(p.latitude, p.longitude)
        : (widget.destination ?? const ll.LatLng(20.5937, 78.9629));
    return ml.MapLibreMap(
      styleString: styleUrl,
      initialCameraPosition: ml.CameraPosition(
        target: ml.LatLng(center.latitude, center.longitude),
        zoom: _lastZoom,
        bearing: _lastBearing,
        tilt: _tilt,
      ),
      myLocationEnabled: true,
      myLocationRenderMode: ml.MyLocationRenderMode.gps,
      compassEnabled: true,
      tiltGesturesEnabled: true,
      rotateGesturesEnabled: true,
      onMapCreated: (ml.MapLibreMapController c) async {
        _controller = c;
        try {
          await _buildLayers();
          _styleReady.complete();
          unawaited(_updateCamera());
        } catch (_) {
          if (!_failed) {
            _failed = true;
            if (mounted) widget.onUnavailable();
          }
        }
      },
    );
  }

  @override
  void didUpdateWidget(NavMap3D old) {
    super.didUpdateWidget(old);
    final ml.MapLibreMapController? c = _controller;
    if (c == null || !_styleReady.isCompleted) return;
    // Route changed → refresh the GeoJSON source in place.
    if (widget.routeLine.length != _lastRoute.length ||
        (widget.routeLine.isNotEmpty &&
            _lastRoute.isNotEmpty &&
            (widget.routeLine.first != _lastRoute.first ||
                widget.routeLine.last != _lastRoute.last))) {
      _lastRoute = List<ll.LatLng>.of(widget.routeLine);
      c.setGeoJsonSource('nav_route_src', _routeGeoJson());
    }
    if (widget.destination != _lastDest) {
      _lastDest = widget.destination;
      c.setGeoJsonSource('nav_dest_src', _destGeoJson());
    }
    if (widget.follow) unawaited(_updateCamera());
  }
}
