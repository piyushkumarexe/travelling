// 🗺️ 3D navigation map for Live Trip — MapLibre GL with camera tilt
// (true perspective view), heading-up bearing and speed-adaptive zoom, plus
// 3D building extrusions from MapTiler's v3 vector tileset.
//
// Reuses the SAME MapTiler key/config as the 2D map (AppConfig). Needs a
// key because vector styles are MapTiler-hosted; without one the parent
// screen keeps the working 2D map (never a blank screen).

import 'dart:async' show Completer, Timer, unawaited;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
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
  Timer? _styleTimeout;
  double _lastBearing = 0;
  double _lastZoom = 16.5;
  List<ll.LatLng> _lastRoute = const <ll.LatLng>[];
  ll.LatLng? _lastDest;

  // A steeper perspective exposes the façades instead of showing mostly
  // flat grey footprints. This is close to the perspective used by turn-by-
  // turn navigation apps while still leaving enough road visible ahead.
  static const double _tilt = 62.0;

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
    // 3D buildings (optional): use the real building metadata from
    // MapTiler Planet v3 instead of painting every footprint the same grey.
    // The `colour` field carries OSM facade colours; render_height and
    // render_min_height carry the actual footprint heights. A vector-tile
    // hiccup must never kill the route/pin layers.
    // A real façade pattern makes the vertical faces read as windows and
    // floors instead of a single grey slab. Roof layers are drawn over it, so
    // the pattern is confined to the walls. If an asset/style implementation
    // cannot register images, the colored extrusion remains the fallback.
    String? facadePatternImage;
    try {
      final ByteData patternBytes = await rootBundle.load(
        'assets/images/building_facade_pattern.png',
      );
      await c.addImage(
        'nav_building_facade_pattern',
        patternBytes.buffer.asUint8List(),
      );
      facadePatternImage = 'nav_building_facade_pattern';
    } catch (_) {
      // The texture is decorative — never block the navigation map.
    }
    final String? tilesJson = AppConfig.vectorTilesJsonUrl;
    if (tilesJson != null) {
      try {
        await c.addSource(
          'nav_buildings_src',
          ml.VectorSourceProperties(url: tilesJson),
        );

        final List<dynamic> heightExpression = <dynamic>[
          'max',
          4.5,
          <dynamic>[
            'coalesce',
            <dynamic>['get', 'render_height'],
            <dynamic>['get', 'height'],
            <dynamic>[
              '*',
              <dynamic>['coalesce', <dynamic>['get', 'levels'], 2],
              3.2,
            ],
            8.0,
          ],
        ];
        final List<dynamic> baseExpression = <dynamic>[
          'coalesce',
          <dynamic>['get', 'render_min_height'],
          <dynamic>['get', 'height_min'],
          0.0,
        ];
        // Fade buildings in as the camera reaches a useful 3D zoom. This
        // avoids the flat pop-in effect when the user zooms toward a place.
        final List<dynamic> scaledHeight = <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          <dynamic>['zoom'],
          14.0,
          0.0,
          15.5,
          heightExpression,
        ];
        // Planet v3 does not consistently provide a building class. Use
        // height-driven materials instead of falling back to one grey color
        // when that optional property is absent. The dedicated Buildings
        // overlay below uses its facade_color and roof_color fields directly.
        final List<dynamic> facadeColor = <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          heightExpression,
          4.5,
          '#D7A27C',
          8.0,
          '#C48561',
          16.0,
          '#A96F55',
          30.0,
          '#80695D',
          60.0,
          '#657586',
          120.0,
          '#4F6374',
        ];
        final List<dynamic> roofColor = <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          heightExpression,
          4.5,
          '#8F5C45',
          12.0,
          '#765347',
          30.0,
          '#596875',
          120.0,
          '#354453',
        ];
        // The cap is still a flat MapLibre extrusion, but a slightly deeper
        // material band makes roof_shape distinctions legible without
        // pretending this vector source contains sloped 3D meshes.
        final List<dynamic> roofThickness = <dynamic>[
          'match',
          <dynamic>['get', 'roof_shape'],
          'gabled',
          0.55,
          'hipped',
          0.45,
          'pyramidal',
          0.45,
          'shed',
          0.35,
          0.28,
        ];
        final List<dynamic> buildingFilter = <dynamic>[
          'all',
          <dynamic>['!=', <dynamic>['get', 'hide_3d'], true],
          <dynamic>['!=', <dynamic>['get', 'underground'], true],
        ];

        await c.addFillExtrusionLayer(
          'nav_buildings_src',
          'nav_buildings_3d',
          ml.FillExtrusionLayerProperties(
            fillExtrusionColor: facadeColor,
            fillExtrusionHeight: scaledHeight,
            fillExtrusionBase: baseExpression,
            fillExtrusionOpacity: 0.98,
            fillExtrusionVerticalGradient: true,
          ),
          belowLayerId: 'nav_route_casing',
          sourceLayer: 'building',
          minzoom: 14,
          filter: buildingFilter,
          enableInteraction: false,
        );

        // Keep the colored extrusion as the guaranteed fallback. The window
        // texture is a separate layer so an older native renderer that cannot
        // use fill-extrusion-pattern still leaves visible buildings behind.
        if (facadePatternImage != null) {
          try {
            await c.addFillExtrusionLayer(
              'nav_buildings_src',
              'nav_buildings_facade_detail',
              ml.FillExtrusionLayerProperties(
                fillExtrusionColor: facadeColor,
                fillExtrusionPattern: facadePatternImage,
                fillExtrusionHeight: scaledHeight,
                fillExtrusionBase: baseExpression,
                fillExtrusionOpacity: 0.98,
                fillExtrusionVerticalGradient: true,
              ),
              belowLayerId: 'nav_route_casing',
              sourceLayer: 'building',
              minzoom: 15,
              filter: buildingFilter,
              enableInteraction: false,
            );
          } catch (_) {
            // Texture unsupported — the colored wall layer remains.
          }
        }

        // A thin roof cap gives each building a readable top surface and
        // makes adjacent footprints look like buildings, not grey blocks.
        await c.addFillExtrusionLayer(
          'nav_buildings_src',
          'nav_buildings_roofs',
          ml.FillExtrusionLayerProperties(
            fillExtrusionColor: roofColor,
            fillExtrusionHeight: scaledHeight,
            fillExtrusionBase: <dynamic>[
              'max',
              0.0,
              <dynamic>['-', scaledHeight, roofThickness],
            ],
            fillExtrusionOpacity: 0.96,
            fillExtrusionVerticalGradient: false,
          ),
          belowLayerId: 'nav_route_casing',
          sourceLayer: 'building',
          minzoom: 14,
          filter: buildingFilter,
          enableInteraction: false,
        );

        // Fine outlines separate neighbouring buildings and preserve the
        // footprint detail when imagery is low contrast.
        await c.addLineLayer(
          'nav_buildings_src',
          'nav_buildings_outline',
          ml.LineLayerProperties(
            lineColor: '#7B8794',
            lineWidth: 0.65,
            lineOpacity: 0.55,
            lineJoin: 'round',
          ),
          belowLayerId: 'nav_route_casing',
          sourceLayer: 'building',
          minzoom: 15,
          filter: buildingFilter,
          enableInteraction: false,
        );
      } catch (_) {
        // Buildings are decorative — ignore.
      }

      // MapTiler's dedicated Buildings tileset carries building-part geometry
      // and real facade/roof metadata. It is an overlay rather than a hard
      // replacement: if the account or network cannot serve it, the Planet v3
      // layer above still gives the user a complete 3D map.
      final String? detailedTilesJson =
          AppConfig.detailedBuildingsTilesJsonUrl;
      if (detailedTilesJson != null) {
        try {
          await c.addSource(
            'nav_building_details_src',
            ml.VectorSourceProperties(url: detailedTilesJson),
          );
          final List<dynamic> detailHeight = <dynamic>[
            'max',
            4.5,
            <dynamic>[
              'coalesce',
              <dynamic>['get', 'height'],
              <dynamic>[
                '*',
                <dynamic>['coalesce', <dynamic>['get', 'levels'], 2],
                3.2,
              ],
              8.0,
            ],
          ];
          final List<dynamic> detailScaledHeight = <dynamic>[
            'interpolate',
            <dynamic>['linear'],
            <dynamic>['zoom'],
            14.0,
            0.0,
            15.5,
            detailHeight,
          ];
          final List<dynamic> detailBase = <dynamic>[
            'coalesce',
            <dynamic>['get', 'height_min'],
            0.0,
          ];
          final List<dynamic> detailClassFacadeColor = <dynamic>[
            'match',
            <dynamic>['get', 'class'],
            'residential',
            '#C7B39B',
            'commercial',
            '#AAB8C5',
            'industrial',
            '#8F9BA6',
            'education',
            '#D0B083',
            'civic',
            '#B7C5D1',
            'religious',
            '#B78F6C',
            '#B3BBC2',
          ];
          final List<dynamic> detailClassRoofColor = <dynamic>[
            'match',
            <dynamic>['get', 'roof_shape'],
            'gabled',
            '#765E52',
            'hipped',
            '#6F625A',
            'pyramidal',
            '#745A49',
            'shed',
            '#667482',
            'flat',
            '#707B85',
            '#7B858E',
          ];
          final List<dynamic> detailFacadeColor = <dynamic>[
            'coalesce',
            <dynamic>['get', 'facade_color'],
            detailClassFacadeColor,
          ];
          final List<dynamic> detailRoofColor = <dynamic>[
            'coalesce',
            <dynamic>['get', 'roof_color'],
            detailClassRoofColor,
          ];
          final List<dynamic> detailRoofThickness = <dynamic>[
            'match',
            <dynamic>['get', 'roof_shape'],
            'gabled',
            0.55,
            'hipped',
            0.45,
            'pyramidal',
            0.45,
            'shed',
            0.35,
            0.28,
          ];
          final List<dynamic> detailFilter = <dynamic>[
            'all',
            <dynamic>['!=', <dynamic>['get', 'underground'], true],
          ];

          await c.addFillExtrusionLayer(
            'nav_building_details_src',
            'nav_building_details_3d',
            ml.FillExtrusionLayerProperties(
              fillExtrusionColor: detailFacadeColor,
              fillExtrusionHeight: detailScaledHeight,
              fillExtrusionBase: detailBase,
              fillExtrusionOpacity: 1.0,
              fillExtrusionVerticalGradient: true,
            ),
            belowLayerId: 'nav_route_casing',
            sourceLayer: 'building',
            minzoom: 14,
            filter: detailFilter,
            enableInteraction: false,
          );
          if (facadePatternImage != null) {
            try {
              await c.addFillExtrusionLayer(
                'nav_building_details_src',
                'nav_building_details_facade_detail',
                ml.FillExtrusionLayerProperties(
                  fillExtrusionColor: detailFacadeColor,
                  fillExtrusionPattern: facadePatternImage,
                  fillExtrusionHeight: detailScaledHeight,
                  fillExtrusionBase: detailBase,
                  fillExtrusionOpacity: 1.0,
                  fillExtrusionVerticalGradient: true,
                ),
                belowLayerId: 'nav_route_casing',
                sourceLayer: 'building',
                minzoom: 15,
                filter: detailFilter,
                enableInteraction: false,
              );
            } catch (_) {
              // Texture unsupported — the colored wall layer remains.
            }
          }
          await c.addFillExtrusionLayer(
            'nav_building_details_src',
            'nav_building_details_roofs',
            ml.FillExtrusionLayerProperties(
              fillExtrusionColor: detailRoofColor,
              fillExtrusionHeight: detailScaledHeight,
              fillExtrusionBase: <dynamic>[
                'max',
                0.0,
                <dynamic>['-', detailScaledHeight, detailRoofThickness],
              ],
              fillExtrusionOpacity: 1.0,
              fillExtrusionVerticalGradient: false,
            ),
            belowLayerId: 'nav_route_casing',
            sourceLayer: 'building',
            minzoom: 14,
            filter: detailFilter,
            enableInteraction: false,
          );
          await c.addLineLayer(
            'nav_building_details_src',
            'nav_building_details_outline',
            ml.LineLayerProperties(
              lineColor: '#56616B',
              lineWidth: 0.7,
              lineOpacity: 0.68,
              lineJoin: 'round',
            ),
            belowLayerId: 'nav_route_casing',
            sourceLayer: 'building',
            minzoom: 15,
            filter: detailFilter,
            enableInteraction: false,
          );
        } catch (_) {
          // The detailed tileset is an enhancement, never a map prerequisite.
        }
      }
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
      onMapCreated: (ml.MapLibreMapController c) {
        _controller = c;
        // If the style never finishes loading (network/style problem),
        // fall back to the 2D map instead of showing a bare surface.
        _styleTimeout = Timer(const Duration(seconds: 12), () {
          if (!_styleReady.isCompleted && !_failed && mounted) {
            _failed = true;
            widget.onUnavailable();
          }
        });
      },
      onStyleLoadedCallback: () async {
        // Sources/layers can only be added AFTER the style is loaded —
        // doing this in onMapCreated throws "style not loaded".
        if (_styleReady.isCompleted) return;
        try {
          await _buildLayers();
          _styleTimeout?.cancel();
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
  void dispose() {
    _styleTimeout?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(NavMap3D old) {
    super.didUpdateWidget(old);
    final ml.MapLibreMapController? c = _controller;
    if (c == null || !_styleReady.isCompleted || _failed) return;
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
