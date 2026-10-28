// 🗺️ 3D navigation map for Live Trip — MapLibre GL with camera tilt
// (true perspective view), heading-up bearing and speed-adaptive zoom, plus
// 3D building extrusions from MapTiler's v3 vector tileset.
//
// Reuses the SAME MapTiler key/config as the 2D map (AppConfig). Needs a
// key because vector styles are MapTiler-hosted; without one the parent
// screen keeps the working 2D map (never a blank screen).

import 'dart:async' show Completer, Timer, unawaited;
import 'dart:math' as math;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart' show Position;
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../../../core/app_config.dart';

/// A circular area to paint on the 3D map (safety zone, geofence, …).
/// Deliberately free of the safety-domain model so the 3D widget stays a
/// reusable map component.
class Map3DZone {
  const Map3DZone({
    required this.name,
    required this.lat,
    required this.lng,
    required this.radiusMeters,
    required this.colorHex,
  });

  final String name;
  final double lat;
  final double lng;
  final double radiusMeters;

  /// '#RRGGBB' — fill + outline colour, chosen by the caller.
  final String colorHex;
}

/// A point to label on the 3D map (a search result, a saved place, …).
class Map3DPin {
  const Map3DPin({
    required this.name,
    required this.lat,
    required this.lng,
    this.colorHex = '#2563EB',
  });

  final String name;
  final double lat;
  final double lng;
  final String colorHex;
}

class NavMap3D extends StatefulWidget {
  const NavMap3D({
    super.key,
    required this.position,
    required this.routeLine,
    required this.destination,
    required this.follow,
    required this.satellite,
    required this.onUnavailable,
    this.onTap,
    this.onLongPress,
    this.zones = const <Map3DZone>[],
    this.pins = const <Map3DPin>[],
  });

  /// Latest device fix from the existing location stream.
  final Position? position;
  final List<ll.LatLng> routeLine;
  final ll.LatLng? destination;

  /// Google-style follow camera (bearing = travel direction + tilt).
  final bool follow;

  /// Reuses the Live Trip satellite toggle (hybrid imagery vs streets).
  final bool satellite;

  /// Safety/geofence areas to paint under the route. Null or empty = none.
  final List<Map3DZone> zones;

  /// Extra points to label (the Map tab's search results, so switching to 3D
  /// does not make the places you just searched for disappear).
  final List<Map3DPin> pins;

  /// Optional location-picking callbacks. MapLibre coordinates are converted
  /// to the shared latlong2 type before leaving this widget.
  final ValueChanged<ll.LatLng>? onTap;
  final ValueChanged<ll.LatLng>? onLongPress;

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
  double _lastZoom = 17.5;
  List<ll.LatLng> _lastRoute = const <ll.LatLng>[];
  ll.LatLng? _lastDest;

  // A steeper perspective exposes the façades instead of showing mostly
  // flat grey footprints. This is close to the perspective used by turn-by-
  // turn navigation apps while still leaving enough road visible ahead.
  static const double _tilt = 62.0;

  String? get _styleUrl =>
      AppConfig.styleJsonUrl(widget.satellite ? 'hybrid' : 'streets-v2');

  /// True once the camera has been pointed at the traveller. The first GPS
  /// fix often lands a beat AFTER the map is built (cold start), so an
  /// explore-mode 3D view would otherwise open on the whole of India and stay
  /// there — it now jumps to the user once, then leaves their panning alone.
  bool _autoCentered = false;

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
    return 17.5;
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

  /// Zones as circle polygons. A circle is approximated with 48 points —
  /// smooth enough at city zoom and cheap enough to build on the UI thread.
  Map<String, dynamic> _zonesGeoJson() {
    const int steps = 48;
    final List<Map<String, dynamic>> features = <Map<String, dynamic>>[];
    for (final Map3DZone z in widget.zones) {
      if (!z.radiusMeters.isFinite || z.radiusMeters <= 0) continue;
      if (!z.lat.isFinite || !z.lng.isFinite) continue;
      final List<List<double>> ring = <List<double>>[];
      final double latKm = z.radiusMeters / 1000 / 111.32;
      final double lngKm = z.radiusMeters /
          1000 /
          (111.32 * math.cos(z.lat * math.pi / 180).abs().clamp(0.05, 1.0));
      for (int i = 0; i <= steps; i++) {
        final double a = 2 * math.pi * i / steps;
        ring.add(<double>[
          z.lng + lngKm * math.sin(a),
          z.lat + latKm * math.cos(a),
        ]);
      }
      features.add(<String, dynamic>{
        'type': 'Feature',
        'properties': <String, dynamic>{
          'name': z.name,
          'color': z.colorHex,
        },
        'geometry': <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <List<List<double>>>[ring],
        },
      });
    }
    return <String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    };
  }

  Map<String, dynamic> _pinsGeoJson() => <String, dynamic>{
        'type': 'FeatureCollection',
        'features': <Map<String, dynamic>>[
          for (final Map3DPin p in widget.pins)
            <String, dynamic>{
              'type': 'Feature',
              'properties': <String, dynamic>{
                'name': p.name,
                'color': p.colorHex,
              },
              'geometry': <String, dynamic>{
                'type': 'Point',
                'coordinates': <double>[p.lng, p.lat],
              },
            },
        ],
      };

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
    // Zones first, so the route always reads above them.
    if (widget.zones.isNotEmpty) {
      try {
        await c.addGeoJsonSource('nav_zones_src', _zonesGeoJson());
        await c.addFillLayer(
          'nav_zones_src',
          'nav_zones_fill',
          ml.FillLayerProperties(
            fillColor: <dynamic>['get', 'color'],
            fillOpacity: 0.18,
          ),
          belowLayerId: 'nav_route_casing',
          enableInteraction: false,
        );
        await c.addLineLayer(
          'nav_zones_src',
          'nav_zones_outline',
          ml.LineLayerProperties(
            lineColor: <dynamic>['get', 'color'],
            lineWidth: 2,
            lineOpacity: 0.85,
          ),
          belowLayerId: 'nav_route_casing',
          enableInteraction: false,
        );
        await c.addSymbolLayer(
          'nav_zones_src',
          'nav_zone_labels',
          ml.SymbolLayerProperties(
            textField: '{name}',
            textSize: 12,
            textColor: <dynamic>['get', 'color'],
            textHaloColor: '#FFFFFF',
            textHaloWidth: 1.6,
          ),
          belowLayerId: 'nav_route_casing',
          minzoom: 11,
          enableInteraction: false,
        );
      } catch (_) {
        // Zones are an overlay — never block the map.
      }
    }

    // Search results / saved places, so switching to 3D keeps what the
    // traveller just searched for on screen.
    if (widget.pins.isNotEmpty) {
      try {
        await c.addGeoJsonSource('nav_pins_src', _pinsGeoJson());
        await c.addCircleLayer(
          'nav_pins_src',
          'nav_pins_circle',
          ml.CircleLayerProperties(
            circleRadius: 7,
            circleColor: <dynamic>['get', 'color'],
            circleStrokeWidth: 3,
            circleStrokeColor: '#FFFFFF',
          ),
          belowLayerId: 'nav_route_casing',
          enableInteraction: false,
        );
        await c.addSymbolLayer(
          'nav_pins_src',
          'nav_pins_labels',
          ml.SymbolLayerProperties(
            textField: '{name}',
            textSize: 12,
            textColor: '#0F172A',
            textHaloColor: '#FFFFFF',
            textHaloWidth: 2,
            textOffset: <dynamic>[0, 1.4],
            textAnchor: 'top',
            textOptional: true,
          ),
          belowLayerId: 'nav_route_casing',
          minzoom: 12,
          enableInteraction: false,
        );
      } catch (_) {
        // Pins are decorative — the results list still works without them.
      }
    }

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
        // Starting one zoom level earlier is what turns "one extruded block
        // in front of the car" into an actual 3D city around the route.
        final List<dynamic> scaledHeight = <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          <dynamic>['zoom'],
          13.0,
          0.0,
          15.0,
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
          minzoom: 13,
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
          minzoom: 13,
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
            13.0,
            0.0,
            15.0,
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
          minzoom: 13,
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
          minzoom: 13,
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

      // ── the street network over the imagery ────────────────────────────
      // MapTiler's "hybrid" style is aerial imagery plus a few big-road
      // labels. Under a tilted 3D camera that leaves buildings standing on a
      // photo with no lane, service road or footpath under them — exactly the
      // "chhoti sadkein render nahi ho rahin" complaint. The Planet tileset
      // already loaded above carries a full transportation layer, so draw it
      // (casing + fill, then the fine classes up close) and label the
      // streets. Everything is inserted BELOW the building extrusions: roads
      // painted over rooftops look worse than no roads at all.
      if (widget.satellite) {
        // Buildings are optional, so the anchor layer may not exist — fall
        // back to the route casing, which always does.
        Future<void> addLine(
          String id,
          ml.LineLayerProperties props, {
          required String sourceLayer,
          double? minzoom,
          List<dynamic>? filter,
        }) async {
          for (final String below in <String>[
            'nav_buildings_3d',
            'nav_route_casing',
          ]) {
            try {
              await c.addLineLayer(
                'nav_buildings_src',
                id,
                props,
                belowLayerId: below,
                sourceLayer: sourceLayer,
                minzoom: minzoom,
                filter: filter,
                enableInteraction: false,
              );
              return;
            } catch (_) {
              // Try the next anchor.
            }
          }
        }

        try {
          final List<dynamic> roadWidth = <dynamic>[
            'interpolate',
            <dynamic>['linear'],
            <dynamic>['zoom'],
            11.5,
            <dynamic>[
              'match',
              <dynamic>['get', 'class'],
              'motorway', 1.1,
              'trunk', 1.0,
              'primary', 0.9,
              'secondary', 0.8,
              0.45,
            ],
            14.0,
            <dynamic>[
              'match',
              <dynamic>['get', 'class'],
              'motorway', 3.4,
              'trunk', 3.0,
              'primary', 2.7,
              'secondary', 2.3,
              'tertiary', 1.8,
              1.15,
            ],
            16.5,
            <dynamic>[
              'match',
              <dynamic>['get', 'class'],
              'motorway', 8.2,
              'trunk', 7.2,
              'primary', 6.4,
              'secondary', 5.4,
              'tertiary', 4.3,
              3.0,
            ],
          ];
          await addLine(
            'nav_roads_casing',
            ml.LineLayerProperties(
              lineColor: '#1D232B',
              lineWidth: <dynamic>['*', roadWidth, 1.85],
              lineOpacity: 0.55,
              lineJoin: 'round',
              lineCap: 'round',
            ),
            sourceLayer: 'transportation',
            minzoom: 11,
          );
          await addLine(
            'nav_roads_fill',
            ml.LineLayerProperties(
              lineColor: '#F5F7FA',
              lineWidth: roadWidth,
              lineOpacity: 0.94,
              lineJoin: 'round',
              lineCap: 'round',
            ),
            sourceLayer: 'transportation',
            minzoom: 11,
          );
          // Lanes, service roads and footpaths only exist in the tiles from
          // ~z14 up. Pulling them in earlier would bury the map under every
          // field track in the district.
          await addLine(
            'nav_roads_minor',
            ml.LineLayerProperties(
              lineColor: '#EDEFF3',
              lineWidth: <dynamic>[
                'interpolate',
                <dynamic>['linear'],
                <dynamic>['zoom'],
                14.0,
                0.7,
                17.0,
                2.6,
              ],
              lineOpacity: 0.9,
              lineJoin: 'round',
            ),
            sourceLayer: 'transportation',
            minzoom: 14,
            filter: <dynamic>[
              'any',
              <dynamic>['==', <dynamic>['get', 'class'], 'service'],
              <dynamic>['==', <dynamic>['get', 'class'], 'minor'],
              <dynamic>['==', <dynamic>['get', 'class'], 'residential'],
              <dynamic>['==', <dynamic>['get', 'class'], 'track'],
              <dynamic>['==', <dynamic>['get', 'class'], 'path'],
              <dynamic>['==', <dynamic>['get', 'class'], 'footway'],
              <dynamic>['==', <dynamic>['get', 'class'], 'cycleway'],
              <dynamic>['==', <dynamic>['get', 'class'], 'pedestrian'],
            ],
          );
          // Street names follow the road, with a halo: white text on an
          // aerial photo is unreadable without one.
          for (final String below in <String>[
            'nav_buildings_3d',
            'nav_route_casing',
          ]) {
            try {
              await c.addSymbolLayer(
                'nav_buildings_src',
                'nav_street_labels',
                ml.SymbolLayerProperties(
                  symbolPlacement: 'line',
                  textField: '{name}',
                  textSize: <dynamic>[
                    'interpolate',
                    <dynamic>['linear'],
                    <dynamic>['zoom'],
                    14.5,
                    10.0,
                    17.0,
                    13.0,
                  ],
                  textColor: '#FFFFFF',
                  textHaloColor: '#111820',
                  textHaloWidth: 1.5,
                ),
                belowLayerId: below,
                sourceLayer: 'transportation_name',
                minzoom: 14.5,
                enableInteraction: false,
              );
              break;
            } catch (_) {
              // Try the next anchor.
            }
          }
        } catch (_) {
          // A style without those source layers simply keeps the imagery.
        }
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
      onMapClick: (math.Point<double> _, ml.LatLng point) =>
          widget.onTap?.call(ll.LatLng(point.latitude, point.longitude)),
      onMapLongClick: (math.Point<double> _, ml.LatLng point) => widget
          .onLongPress
          ?.call(ll.LatLng(point.latitude, point.longitude)),
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
      // Search selection must visibly move to the result in 3D as it does in
      // the flat map. Previously only the hidden destination source changed,
      // leaving the camera over the user's old neighbourhood.
      if (!widget.follow && widget.destination != null) {
        unawaited(_centreOnDestination(widget.destination!));
      }
    }
    if (widget.follow) {
      unawaited(_updateCamera());
    } else if (!_autoCentered && widget.position != null) {
      // Free-look (Map tab): centre on the traveller the moment the first
      // fix exists, then never fight their gestures again.
      _autoCentered = true;
      unawaited(_centreOnUser());
    }
  }

  Future<void> _centreOnDestination(ll.LatLng destination) async {
    final ml.MapLibreMapController? c = _controller;
    if (c == null || !mounted || !_styleReady.isCompleted) return;
    try {
      await c.animateCamera(
        ml.CameraUpdate.newCameraPosition(
          ml.CameraPosition(
            target: ml.LatLng(destination.latitude, destination.longitude),
            zoom: 17.0,
            bearing: 0,
            tilt: _tilt,
          ),
        ),
        duration: const Duration(milliseconds: 450),
      );
    } catch (_) {
      // Style/camera races are harmless; the destination pin still updates.
    }
  }

  /// One-shot "put the camera where the user is" for explore mode.
  Future<void> _centreOnUser() async {
    final ml.MapLibreMapController? c = _controller;
    final Position? p = widget.position;
    if (c == null || p == null || !mounted) return;
    if (!_styleReady.isCompleted) return;
    _lastLat = p.latitude;
    _lastLng = p.longitude;
    try {
      await c.animateCamera(
        ml.CameraUpdate.newCameraPosition(
          ml.CameraPosition(
            target: ml.LatLng(p.latitude, p.longitude),
            zoom: _lastZoom,
            bearing: 0,
            tilt: _tilt,
          ),
        ),
        duration: const Duration(milliseconds: 400),
      );
    } catch (_) {
      // Camera races during style load are harmless.
    }
  }
}
