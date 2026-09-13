import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';

import '../../../core/app_config.dart';
import '../../../core/state/app_container.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/badges.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/incident.dart';
import '../../../data/models/places.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/safety_zone.dart';

/// Interactive map (MapTiler raster tiles — no Google Maps SDK key needed):
/// GPS location, zoom/pan, place search, tourist attractions, nearby places,
/// safety zones, emergency services, destination markers, route info and
/// real turn-by-turn navigation on the device.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    this.initialLat,
    this.initialLng,
    this.initialName,
  });

  /// When set (e.g. coming from a place detail screen), the map focuses
  /// here on open.
  final double? initialLat;
  final double? initialLng;
  final String? initialName;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  AppContainer get _c => AppScope.of(context);

  final MapController _controller = MapController();
  bool _ready = false;
  String? _setupError;
  LatLng _initialCenter = const LatLng(20.5937, 78.9629);
  double _initialZoom = 4;

  /// Current tile style: 'streets-v2' (default, most reliable on the free
  /// tier) with satellite/hybrid available via the layer toggle.
  String _mapStyle = 'streets-v2';

  /// Non-null message when the map needs to show an honest diagnostic banner
  /// (tiles failed on both sources, or the compiled MapTiler key was
  /// rejected at runtime). The map itself keeps rendering, never blank.
  String? _tileNotice;

  /// True when MapTiler rejected the compiled key at runtime — the map then
  /// switches to keyless OpenStreetMap tiles and explains why.
  bool _maptilerRejected = false;

  /// Travel mode for routing + the on-map icon: walk | bike | car | auto.
  String _travelMode = 'car';

  static const List<(String, IconData, String)> _modes =
      <(String, IconData, String)>[
    ('walk', Icons.directions_walk, 'Walk'),
    ('bike', Icons.directions_bike, 'Bike'),
    ('car', Icons.directions_car, 'Car'),
    ('auto', Icons.electric_rickshaw, 'Auto'),
  ];

  IconData _modeIcon(String mode) => switch (mode) {
        'walk' => Icons.directions_walk,
        'bike' => Icons.directions_bike,
        'car' => Icons.directions_car,
        'auto' => Icons.electric_rickshaw,
        _ => Icons.directions_car,
      };

  String _modeLabel(String mode) => switch (mode) {
        'walk' => 'Walking',
        'bike' => 'Biking',
        'car' => 'Car',
        'auto' => 'Auto',
        _ => 'Car',
      };

  Color _modeColor(String mode) => switch (mode) {
        'walk' => const Color(0xFF16A34A),
        'bike' => const Color(0xFF7C3AED),
        'car' => const Color(0xFF2563EB),
        'auto' => const Color(0xFFD97706),
        _ => const Color(0xFF2563EB),
      };

  Position? _position;
  bool _permissionDenied = false;

  /// Optional start point; null means "my location" (default).
  LatLng? _origin;
  String? _originName;
  bool _settingOrigin = false;

  /// Routes per mode for the "fastest way" comparison.
  Map<String, RouteInfo> _routesByMode = <String, RouteInfo>{};
  bool _comparingModes = false;

  /// When true the camera follows the live GPS position (real-time tracking).
  bool _follow = false;
  bool _autoCentered = false;

  List<Marker> _markers = <Marker>[];
  List<CircleMarker> _circles = <CircleMarker>[];
  List<Polyline> _polylines = <Polyline>[];

  Place? _selected;
  RouteInfo? _route;
  bool _routeLoading = false;
  double? _distanceToSelected;

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<Place> _results = const <Place>[];
  bool _resultsVisible = false;
  bool _searchLoading = false;
  String? _searchError;

  List<SafetyZone> _zones = const <SafetyZone>[];
  bool _showZones = true;

  List<Incident> _incidents = const <Incident>[];
  bool _showIncidents = true;
  String? _activeChip;

  StreamSubscription<List<SafetyZone>>? _zonesSub;
  StreamSubscription<List<Incident>>? _incidentsSub;
  StreamSubscription<Position>? _posSub;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadVehicleMode();
    _zonesSub = _c.zonesRepository.watchAll().listen(
          (List<SafetyZone> z) {
        if (mounted) {
          setState(() => _zones = z);
          _rebuildZones();
        }
      },
      onError: (Object _) {},
        );
    _startIncidentsWatch();
    _startPositionWatch();
    _resolveInitial();
    // Runtime diagnostic (sanitized): shows whether a key was compiled in and
    // its length/prefix, so the on-device value can be verified in logcat.
    debugPrint('[map] ${AppConfig.debugMapConfig()}');
    unawaited(_verifyMapKey());
  }

  /// Verifies the compiled MapTiler key with ONE geocoding request so a
  /// rejected key is surfaced honestly (and the map falls back to keyless
  /// OpenStreetMap tiles) instead of rendering MapTiler's "Invalid key"
  /// error tiles. Network failures are ignored — they are not a key problem.
  Future<void> _verifyMapKey() async {
    if (!AppConfig.mapTilerConfigured) return;
    bool ok;
    try {
      ok = await _c.placesRepository.mapTilerKeyValid();
    } catch (_) {
      return; // offline / transient — keep MapTiler as configured.
    }
    if (!mounted || ok) return;
    setState(() {
      _maptilerRejected = true;
      _tileNotice = 'MapTiler rejected the configured key (invalid key). '
          'The map is showing OpenStreetMap tiles instead. Update the '
          'MapTiler key and rebuild the app to restore MapTiler tiles.';
    });
  }

  /// Category markers for incidents (privacy-preserving: no reporter
  /// identity is shown). Regular travelers see their own reports; admins see
  /// all reports. Rules reject unauthenticated list reads, which is handled
  /// here without surfacing raw errors.
  void _startIncidentsWatch() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    final Stream<List<Incident>> stream = _c.authState.isAdmin
        ? _c.incidentsRepository.watchAll()
        : _c.incidentsRepository.watchMine(uid);
    _incidentsSub = stream.listen((List<Incident> items) {
      if (mounted) setState(() => _incidents = items);
    }, onError: (Object _) {});
  }

  Future<void> _resolveInitial() async {
    final double? lat = widget.initialLat;
    final double? lng = widget.initialLng;
    if (lat != null && lng != null) {
      // Reject invalid destination coordinates before rendering — never draw
      // a map centered on NaN/out-of-range values (which looks blank).
      if (!lat.isFinite ||
          !lng.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        setState(() {
          _ready = true;
          _setupError = 'This destination has invalid coordinates, so it '
              'cannot be shown on the map.';
        });
        return;
      }
      // Opened from "Get Directions" / "View on map": focus on the place,
      // drop the destination marker and auto-compute the real OSRM route
      // from the current location (with proper permission handling). The
      // screen never renders an empty/white map — the marker, route and
      // distance/ETA appear even while GPS is still warming up.
      final Place dest = Place(
        placeId: 'dest-${lat.toStringAsFixed(6)}-${lng.toStringAsFixed(6)}',
        name: widget.initialName ?? 'Destination',
        lat: lat,
        lng: lng,
      );
      setState(() {
        _initialCenter = LatLng(lat, lng);
        _initialZoom = 15;
        _ready = true;
        _autoCentered = true;
        _selected = dest;
        _distanceToSelected = _distanceTo(lat, lng);
        _markers = <Marker>[
          Marker(
            point: LatLng(lat, lng),
            width: 40,
            height: 40,
            child: const Icon(Icons.location_pin,
                color: Color(0xFFDC2626), size: 40),
          ),
        ];
      });
      unawaited(_autoRouteFor());
      return;
    }
    // Render the map immediately (country view) instead of blocking on a cold
    // GPS fix. The position watch auto-centers as soon as a real fix lands.
    setState(() => _ready = true);
    try {
      final LocationPermission perm = await _c.locationService.checkPermission();
      if (!mounted) return;
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        setState(() => _permissionDenied = true);
      }
    } catch (_) {}
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted || pos == null) return;
      setState(() {
        _position = pos;
        _initialCenter = LatLng(pos.latitude, pos.longitude);
        _initialZoom = 14;
        _autoCentered = true;
        _permissionDenied = false;
      });
      try {
        _controller.move(LatLng(pos.latitude, pos.longitude), 14);
      } catch (_) {
        // Map not attached yet — the position watch will center it instead.
      }
    } catch (_) {}
  }

  /// After opening the map with a destination, resolve the current location
  /// (prompting for permission) and compute the route — without ever leaving
  /// the screen blank or stuck. On denial the permission banner is shown and
  /// the destination marker stays visible so the user can set a start point.
  Future<void> _autoRouteFor() async {
    if (_position == null) {
      try {
        final LocationPermission perm =
            await _c.locationService.ensurePermission();
        if (!mounted) return;
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          setState(() => _permissionDenied = true);
          return;
        }
        final Position? fixed = await _c.locationService.currentPosition();
        if (mounted && fixed != null) setState(() => _position = fixed);
      } catch (_) {
        // Location unavailable — the destination marker still shows and the
        // user can set a start point manually.
      }
    }
    if (_position == null) return;
    await _getRoute();
  }

  /// Default the travel mode to the vehicle saved in the profile (Vehicle tab)
  /// so the map icon matches how the traveler is actually moving.
  Future<void> _loadVehicleMode() async {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    try {
      final Profile? p = await _c.profileRepository.get(uid);
      if (!mounted || p == null) return;
      final String v = p.vehicle;
      if (v == 'bike' || v == 'car' || v == 'auto') {
        setState(() => _travelMode = v);
      }
    } catch (_) {
      // Profile may be unavailable — keep the default car mode.
    }
  }

  /// Always start live position tracking (even when the map opens focused on
  /// a specific place, so the blue dot, distance and follow-mode work).
  void _startPositionWatch() {
    if (_posSub != null) return;
    _posSub = _c.locationService.watchPosition(distanceFilter: 20).listen(
          (Position p) {
        if (mounted) {
          setState(() => _position = p);
          _updateDistance();
          try {
            if (!_autoCentered) {
              _autoCentered = true;
              _controller.move(LatLng(p.latitude, p.longitude), 14);
            } else if (_follow) {
              _controller.move(
                LatLng(p.latitude, p.longitude),
                _controller.camera.zoom,
              );
            }
          } catch (_) {
            // Map controller not attached yet (first frames) — ignore.
          }
        }
      },
      onError: (Object _) {},
    );
  }

  void _onSearchChanged() {
    final String q = _searchController.text.trim();
    _searchDebounce?.cancel();
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _resultsVisible = false;
          _results = const <Place>[];
        });
      }
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 450), _runSearch);
  }

  Future<void> _runSearch() async {
    final String q = _searchController.text.trim();
    if (q.isEmpty || _searchLoading) return;
    setState(() {
      _searchLoading = true;
      _searchError = null;
    });
    try {
      final gm.LatLng? target = _cameraTarget();
      final List<Place> places = await _c.placesRepository.search(
        q,
        location: target,
        radiusMeters: 10000,
      );
      if (!mounted) return;
      setState(() {
        _results = places;
        _resultsVisible = true;
        _searchLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e.toString();
        _searchLoading = false;
      });
    }
  }

  void _searchCategory(String label, String query, {List<String>? types}) {
    if (_activeChip == label) {
      setState(() => _activeChip = null);
      _searchController.clear();
      setState(() => _resultsVisible = false);
      return;
    }
    setState(() {
      _activeChip = label;
      _searchError = null;
    });
    _searchController.text = query;
    _runSearchWithTypes(query, types);
  }

  Future<void> _runSearchWithTypes(String q, List<String>? types) async {
    setState(() => _searchLoading = true);
    try {
      final gm.LatLng? target = _cameraTarget();
      final List<Place> places = await _c.placesRepository.search(
        q,
        location: target,
        radiusMeters: 8000,
        types: types,
      );
      if (!mounted) return;
      setState(() {
        _results = places;
        _resultsVisible = true;
        _searchLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e.toString();
        _searchLoading = false;
      });
    }
  }

  gm.LatLng? _cameraTarget() {
    final Position? p = _position;
    if (p != null) return gm.LatLng(p.latitude, p.longitude);
    // Fall back to the map's center so search always works near what the
    // user is looking at, even without a GPS fix (Google-style behaviour).
    try {
      final LatLng c = _controller.camera.center;
      return gm.LatLng(c.latitude, c.longitude);
    } catch (_) {
      return null;
    }
  }

  void _rebuildZones() {
    if (!_showZones) {
      _circles = <CircleMarker>[];
      return;
    }
    final List<CircleMarker> circles = <CircleMarker>[];
    for (final SafetyZone z in _zones) {
      if (!z.active) continue;
      // Skip malformed zones so a bad radius/coords can never crash the map.
      if (!z.radiusMeters.isFinite ||
          z.radiusMeters <= 0 ||
          !z.lat.isFinite ||
          !z.lng.isFinite) {
        continue;
      }
      final Color color = RiskBadge.colorFor(context, z.riskLevel);
      circles.add(CircleMarker(
        point: LatLng(z.lat, z.lng),
        radius: z.radiusMeters,
        useRadiusInMeter: true,
        color: color.withValues(alpha: 0.18),
        borderColor: color.withValues(alpha: 0.7),
        borderStrokeWidth: 2,
      ));
    }
    _circles = circles;
  }

  /// Category icon + severity colour for an incident marker.
  IconData _incidentIcon(Incident i) => switch (i.category) {
        'theft' => Icons.directions_run,
        'fraud' => Icons.currency_rupee,
        'assault' => Icons.gavel,
        'harassment' => Icons.report,
        'accident' => Icons.car_crash,
        'unsafe_area' => Icons.dangerous,
        'poor_infrastructure' => Icons.construction,
        'natural_hazard' => Icons.flood,
        _ => Icons.place,
      };

  Color _incidentColor(Incident i) => switch (i.severity) {
        'low' => const Color(0xFF16A34A),
        'medium' => const Color(0xFFF59E0B),
        'high' => const Color(0xFFEA580C),
        'critical' => const Color(0xFFDC2626),
        _ => const Color(0xFFF59E0B),
      };

  List<Marker> _incidentMarkers() {
    final List<Marker> markers = <Marker>[];
    for (final Incident i in _incidents) {
      final Color color = _incidentColor(i);
      markers.add(Marker(
        point: LatLng(i.lat, i.lng),
        width: 32,
        height: 32,
        child: GestureDetector(
          onTap: () => _showIncidentInfo(i),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: <BoxShadow>[
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3), blurRadius: 4),
              ],
            ),
            child: const Icon(Icons.warning_amber,
                size: 16, color: Colors.white),
          ),
        ),
      ));
    }
    return markers;
  }

  /// Privacy-preserving incident details: category, severity, status, time
  /// and distance — never the reporter's identity.
  void _showIncidentInfo(Incident i) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) {
        final ColorScheme scheme = Theme.of(ctx).colorScheme;
        final double? dist = _distanceTo(i.lat, i.lng);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  CircleAvatar(
                    backgroundColor: _incidentColor(i).withValues(alpha: 0.14),
                    child: Icon(_incidentIcon(i),
                        color: _incidentColor(i), size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      i.categoryLabel,
                      style: Theme.of(ctx)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '${i.severityLabel} severity · ${i.statusLabel}',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${Fmt.relative(i.createdAt)}'
                '${dist != null ? ' · ${GeoUtils.formatDistance(dist)} away' : ''}',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              if (i.description.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(i.description,
                    style: Theme.of(ctx).textTheme.bodyMedium),
              ],
              if (i.summary != null && i.summary!.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(i.summary!,
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant)),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _select(Place p) async {
    if (_settingOrigin) {
      // This selection sets the START point (Google-style from/to).
      setState(() {
        _origin = LatLng(p.lat, p.lng);
        _originName = p.name;
        _settingOrigin = false;
        _resultsVisible = false;
        _results = const <Place>[];
        _searchController.clear();
        _activeChip = null;
      });
      if (_selected != null) {
        _route = null;
        _routesByMode = <String, RouteInfo>{};
        _polylines = <Polyline>[];
        unawaited(_getRoute());
      }
      return;
    }
    setState(() {
      _selected = p;
      _route = null;
      _routesByMode = <String, RouteInfo>{};
      _polylines = <Polyline>[];
      _distanceToSelected = _distanceTo(p.lat, p.lng);
      _resultsVisible = false;
      _markers = <Marker>[
        Marker(
          point: LatLng(p.lat, p.lng),
          width: 40,
          height: 40,
          child: const Icon(Icons.location_pin,
              color: Color(0xFFDC2626), size: 40),
        ),
      ];
    });
    _controller.move(LatLng(p.lat, p.lng), 15);
  }

  double? _distanceTo(double lat, double lng) {
    final Position? p = _position;
    if (p == null) return null;
    return GeoUtils.distanceMetersLL(
      p.latitude,
      p.longitude,
      lat,
      lng,
    );
  }

  void _updateDistance() {
    final Place? s = _selected;
    if (s == null) return;
    setState(() => _distanceToSelected = _distanceTo(s.lat, s.lng));
  }

  void _clearSelection() {
    setState(() {
      _selected = null;
      _route = null;
      _routesByMode = <String, RouteInfo>{};
      _markers = <Marker>[];
      _polylines = <Polyline>[];
      _distanceToSelected = null;
    });
  }

  LatLng? _effectiveOrigin() {
    if (_origin != null) return _origin;
    final Position? p = _position;
    if (p != null) return LatLng(p.latitude, p.longitude);
    // No GPS fix yet — use the visible map center so a route always works
    // (Google-style: what you see is where you start from).
    try {
      return _controller.camera.center;
    } catch (_) {
      return null;
    }
  }

  void _toggleSetOrigin() {
    setState(() {
      _settingOrigin = !_settingOrigin;
      _resultsVisible = false;
      _results = const <Place>[];
      _searchController.clear();
      _activeChip = null;
    });
  }

  /// One-tap "set start" from a search result (Google-style from/to).
  void _setOriginFrom(Place p) {
    setState(() {
      _origin = LatLng(p.lat, p.lng);
      _originName = p.name;
      _settingOrigin = false;
      _resultsVisible = false;
      _results = const <Place>[];
      _searchController.clear();
      _activeChip = null;
    });
    if (_selected != null) {
      _route = null;
      _routesByMode = <String, RouteInfo>{};
      _polylines = <Polyline>[];
      unawaited(_getRoute());
    }
  }

  void _clearOrigin() {
    setState(() {
      _origin = null;
      _originName = null;
    });
    if (_selected != null) {
      _route = null;
      _routesByMode = <String, RouteInfo>{};
      _polylines = <Polyline>[];
      if (_position != null) _getRoute();
    }
  }

  void _swapOriginDestination() {
    final Place? dest = _selected;
    if (dest == null) return;
    setState(() {
      final LatLng? oldOrigin = _effectiveOrigin();
      final String? oldOriginName = _originName;
      _origin = LatLng(dest.lat, dest.lng);
      _originName = dest.name;
      _selected = null;
      _route = null;
      _routesByMode = <String, RouteInfo>{};
      _polylines = <Polyline>[];
      if (oldOrigin != null) {
        _selected = Place(
          placeId: 'swap-${DateTime.now().millisecondsSinceEpoch}',
          name: oldOriginName ?? 'Dropped pin',
          lat: oldOrigin.latitude,
          lng: oldOrigin.longitude,
        );
        _distanceToSelected = _distanceTo(
            oldOrigin.latitude, oldOrigin.longitude);
      }
    });
  }

  Future<void> _getRoute() async {
    final Place? p = _selected;
    if (p == null) return;
    final LatLng? from = _effectiveOrigin();
    if (from == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Set your start point or enable GPS — then try again.')),
      );
      return;
    }
    setState(() => _routeLoading = true);
    try {
      final RouteInfo r = await _c.placesRepository.route(
        gm.LatLng(from.latitude, from.longitude),
        gm.LatLng(p.lat, p.lng),
        mode: _travelMode,
      );
      if (!mounted) return;
      setState(() {
        _route = r;
        _routeLoading = false;
        _polylines = r.polyline.length >= 2
            ? <Polyline>[
                Polyline(
                  points: r.polyline
                      .map((gm.LatLng lp) => LatLng(lp.latitude, lp.longitude))
                      .toList(),
                  color: _modeColor(_travelMode),
                  strokeWidth: 5,
                ),
              ]
            : <Polyline>[];
      });
      unawaited(_compareAllModes(from, p));
    } catch (e) {
      if (!mounted) return;
      setState(() => _routeLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not get a route: $e')),
      );
    }
  }

  /// Fetches routes for every mode in parallel and shows the fastest way,
  /// so the traveler sees ETA options like a real navigation app.
  Future<void> _compareAllModes(LatLng from, Place p) async {
    setState(() => _comparingModes = true);
    final Map<String, RouteInfo> results = <String, RouteInfo>{};
    await Future.wait(<String>['walk', 'bike', 'car', 'auto'].map(
      (String mode) async {
        try {
          final RouteInfo r = await _c.placesRepository.route(
            gm.LatLng(from.latitude, from.longitude),
            gm.LatLng(p.lat, p.lng),
            mode: mode,
          );
          results[mode] = r;
        } catch (_) {}
      },
    ));
    if (!mounted) return;
    setState(() {
      _routesByMode = results;
      _comparingModes = false;
    });
  }

  Future<void> _openNavigation() async {
    final Place? p = _selected;
    if (p == null) return;
    await _c.placesRepository.openInGoogleMaps(p.lat, p.lng, p.name);
  }

  void _recenter() {
    final Position? p = _position;
    if (p == null) return;
    _controller.move(LatLng(p.latitude, p.longitude), 15);
  }

  void _toggleStyle() {
    setState(() {
      _mapStyle = switch (_mapStyle) {
        'satellite' => 'hybrid',
        'hybrid' => 'streets-v2',
        _ => 'satellite',
      };
    });
  }

  String get _styleLabel => switch (_mapStyle) {
        'satellite' => 'Satellite',
        'hybrid' => 'Hybrid (satellite + labels)',
        _ => 'Streets',
      };

  /// MapTiler's TileJSON reports maxzoom 22 for `satellite`, `hybrid` and
  /// `streets-v2`. Native zoom is set to the source's real maximum so tiles
  /// are never upscaled/stretched; streets-v2 is capped at 19 to avoid
  /// fetching an excessive number of tiny street tiles.
  int get _maxNativeZoom => _mapStyle == 'streets-v2' ? 19 : 22;

  double get _maxZoom => _mapStyle == 'streets-v2' ? 19 : 22;

  IconData get _styleIcon => switch (_mapStyle) {
        'satellite' => Icons.satellite_alt,
        'hybrid' => Icons.layers,
        _ => Icons.map,
      };

  /// Long-press anywhere to drop a pin, then get the distance, a route and
  /// real turn-by-turn navigation from your location to that point.
  void _dropPin(TapPosition tap, LatLng point) {
    if (_settingOrigin) {
      setState(() {
        _origin = point;
        _originName = 'Dropped pin';
        _settingOrigin = false;
        _resultsVisible = false;
      });
      if (_selected != null) {
        _route = null;
        _routesByMode = <String, RouteInfo>{};
        _polylines = <Polyline>[];
        _getRoute();
      }
      return;
    }
    final Place pin = Place(
      placeId: 'pin-${DateTime.now().millisecondsSinceEpoch}',
      name: 'Dropped pin',
      lat: point.latitude,
      lng: point.longitude,
      address: '${point.latitude.toStringAsFixed(5)}, '
          '${point.longitude.toStringAsFixed(5)}',
    );
    setState(() {
      _selected = pin;
      _route = null;
      _routesByMode = <String, RouteInfo>{};
      _polylines = <Polyline>[];
      _distanceToSelected = _distanceTo(point.latitude, point.longitude);
      _resultsVisible = false;
      _markers = <Marker>[
        Marker(
          point: point,
          width: 40,
          height: 40,
          child: const Icon(Icons.location_pin,
              color: Color(0xFFDC2626), size: 40),
        ),
      ];
    });
    _controller.move(point, _controller.camera.zoom < 15 ? 15 : _controller.camera.zoom);
  }

  void _toggleFollow() {
    final bool on = !_follow;
    setState(() => _follow = on);
    if (on) _recenter();
  }

  Future<void> _enableLocation() async {
    final LocationPermission perm =
        await _c.locationService.ensurePermission();
    if (!mounted) return;
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return;
    }
    final Position? pos = await _c.locationService.currentPosition();
    if (mounted) {
      setState(() {
        _position = pos;
        _permissionDenied = false;
      });
      if (pos != null) {
        _recenter();
      }
      // Restart the live position watch now that permission is granted.
      unawaited(_posSub?.cancel());
      _posSub = null;
      _startPositionWatch();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _zonesSub?.cancel();
    _incidentsSub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: LoadingView(message: 'Loading map…'),
      );
    }
    if (_setupError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Map')),
        body: ErrorState(
          message: _setupError!,
          onRetry: () {
            setState(() => _setupError = null);
            unawaited(_resolveInitial());
          },
        ),
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // MapTiler is used only when a key was compiled in AND it validated at
    // runtime. Otherwise the map renders keyless OpenStreetMap tiles so it
    // never shows MapTiler's "Invalid key" error tiles and never goes blank.
    final bool useMaptiler = AppConfig.mapTilerConfigured && !_maptilerRejected;
    return Scaffold(
      body: Stack(
        children: <Widget>[
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: _initialCenter,
              initialZoom: _initialZoom,
              maxZoom: _maxZoom,
              onTap: (TapPosition _, LatLng __) => _clearSelection(),
              onLongPress: _dropPin,
            ),
            children: <Widget>[
              TileLayer(
                key: ValueKey<String>('$_mapStyle-$useMaptiler'),
                urlTemplate: useMaptiler
                    ? AppConfig.mapTilerTileUrl(_mapStyle)
                    : AppConfig.fallbackTileUrl,
                fallbackUrl: useMaptiler ? AppConfig.fallbackTileUrl : null,
                userAgentPackageName: 'app.roamio.tourism',
                retinaMode: RetinaMode.isHighDensity(context),
                maxNativeZoom: _maxNativeZoom,
                errorTileCallback: (tile, error, stackTrace) {
                  if (_tileNotice == null && mounted) {
                    setState(() {
                      _tileNotice = 'Map tiles could not load. Check your '
                          'internet connection — route lines and markers '
                          'still show.';
                    });
                  }
                },
              ),
              MarkerLayer(
                markers: <Marker>[
                  ..._markers,
                  if (_showIncidents) ..._incidentMarkers(),
                  if (_origin != null) _originMarker(),
                  if (_position != null) _userLocationMarker(),
                ],
              ),
              CircleLayer(circles: _circles),
              PolylineLayer(polylines: _polylines),
              // Legally-required provider attribution only. SimpleAttributionWidget
              // renders exactly the text below — no flutter_map branding is added.
              SimpleAttributionWidget(
                source: Text(
                  useMaptiler
                      ? '© MapTiler  © OpenStreetMap contributors'
                      : '© OpenStreetMap contributors',
                  style: const TextStyle(fontSize: 10, height: 1.2),
                ),
                backgroundColor: scheme.surface.withValues(alpha: 0.75),
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _topBar(),
          ),
          if (_speedKmh >= 1)
            Positioned(
              left: 12,
              bottom: _selected != null ? 300 : 96,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: scheme.outlineVariant),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 8),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.speed,
                        size: 20, color: _modeColor(_travelMode)),
                    const SizedBox(width: 6),
                    Text(
                      '${_speedKmh.round()} km/h',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: _modeColor(_travelMode),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_resultsVisible)
            Positioned(
              top: 148,
              left: 12,
              right: 12,
              child: _resultsSheet(),
            ),
          if (_permissionDenied)
            Positioned(
              top: 200,
              left: 12,
              right: 12,
              child: _permissionBanner(),
            ),
          if (_tileNotice != null)
            Positioned(
              top: 148,
              left: 12,
              right: 12,
              child: _tileNoticeBanner(_tileNotice!),
            ),
          if (_selected != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _selectedSheet(),
            ),
          Positioned(
            right: 16,
            bottom: _selected != null ? 260 : 96,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FloatingActionButton.small(
                  heroTag: 'map-layer-toggle',
                  tooltip: useMaptiler
                      ? '$_styleLabel — tap to switch style'
                      : 'Satellite/hybrid styles need a MapTiler key',
                  onPressed: useMaptiler ? _toggleStyle : null,
                  child: Icon(_styleIcon),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'map-follow',
                  tooltip: _follow
                      ? 'Stop following my location'
                      : 'Follow my location live',
                  backgroundColor: _follow ? scheme.primary : null,
                  foregroundColor: _follow ? scheme.onPrimary : null,
                  onPressed: _toggleFollow,
                  child: Icon(
                    _follow ? Icons.gps_fixed : Icons.gps_not_fixed,
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'map-zoom-in',
                  tooltip: 'Zoom in',
                  onPressed: () => _controller.move(
                    _controller.camera.center,
                    _controller.camera.zoom + 1,
                  ),
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'map-zoom-out',
                  tooltip: 'Zoom out',
                  onPressed: () => _controller.move(
                    _controller.camera.center,
                    _controller.camera.zoom - 1,
                  ),
                  child: const Icon(Icons.remove),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'map-my-location',
                  tooltip: 'My location',
                  onPressed: _recenter,
                  child: const Icon(Icons.my_location),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Marker _originMarker() {
    final LatLng o = _origin!;
    return Marker(
      point: o,
      width: 40,
      height: 40,
      child: const Icon(Icons.trip_origin,
          color: Color(0xFF16A34A), size: 32),
    );
  }

  /// Live speedometer (km/h from the GPS stream).
  double get _speedKmh {
    final Position? p = _position;
    if (p == null || p.speed <= 0) return 0;
    return p.speed * 3.6;
  }

  Marker _userLocationMarker() {
    final Position p = _position!;
    final Color mode = _modeColor(_travelMode);
    // A mode icon (walk / bike / car / auto) instead of a plain dot, so the
    // traveler always sees *how* they're moving on the map.
    return Marker(
      point: LatLng(p.latitude, p.longitude),
      width: 34,
      height: 34,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: mode, width: 2.5),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Colors.black26, blurRadius: 4),
          ],
        ),
        child: Icon(_modeIcon(_travelMode), color: mode, size: 18),
      ),
    );
  }

  Widget _topBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Where do you want to go?',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (_searchLoading)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            if (_searchController.text.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () => _searchController.clear(),
                              ),
                          ],
                        ),
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 8),
                      ),
                      onSubmitted: (String _) => _runSearch(),
                    ),
                  ),
                ),
                // Space for the profile avatar pinned top-right by the shell.
                const SizedBox(width: 52),
              ],
            ),
            const SizedBox(height: 8),
            _travelModeSelector(),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: <Widget>[
                  _chip(
                    _origin == null ? '📍 Set start' : 'Start: ${_originName ?? 'Pin'}',
                    _toggleSetOrigin,
                    active: _settingOrigin || _origin != null,
                  ),
                  if (_origin != null) ...<Widget>[
                    const SizedBox(width: 8),
                    _chip('✕ start', _clearOrigin),
                  ],
                  const SizedBox(width: 8),
                  _chip('Attractions', () => _searchCategory(
                      'Attractions', 'tourist attractions',
                      types: const <String>['tourist_attraction'])),
                  const SizedBox(width: 8),
                  _chip('Food', () => _searchCategory('Food', 'restaurants',
                      types: const <String>['restaurant'])),
                  const SizedBox(width: 8),
                  _chip('Parks', () => _searchCategory('Parks', 'parks',
                      types: const <String>['park'])),
                  const SizedBox(width: 8),
                  _chip('Hospitals', () => _searchCategory(
                      'Hospitals', 'hospitals', types: const <String>['hospital'])),
                  const SizedBox(width: 8),
                  _chip('Police', () => _searchCategory(
                      'Police', 'police stations',
                      types: const <String>['police_station'])),
                  const SizedBox(width: 8),
                  _chip('Fire', () => _searchCategory(
                      'Fire', 'fire stations',
                      types: const <String>['fire_station'])),
                  const SizedBox(width: 8),
                  _chip(
                    'Safety zones',
                    () => setState(() {
                      _showZones = !_showZones;
                      _rebuildZones();
                    }),
                    active: _showZones,
                  ),
                  const SizedBox(width: 8),
                  _chip(
                    'Incidents',
                    () => setState(() => _showIncidents = !_showIncidents),
                    active: _showIncidents,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _settingOrigin
                      ? 'Now choose your START point — search or long-press'
                      : 'Search or long-press the map to set your destination',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Travel-mode selector: picking Walk / Bike / Car / Auto changes the
  /// on-map icon, the route profile and the route colour.
  Widget _travelModeSelector() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: <BoxShadow>[
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6),
        ],
      ),
      child: Row(
        children: <Widget>[
          for (final (String id, IconData icon, String label) in _modes)
            Expanded(
              child: _modeChip(id, icon, label),
            ),
        ],
      ),
    );
  }

  Widget _modeChip(String id, IconData icon, String label) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool active = _travelMode == id;
    final Color color = _modeColor(id);
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        setState(() => _travelMode = id);
        // Recompute the shown route for the new mode when a destination exists.
        if (_selected != null && _route != null) {
          _route = null;
          _polylines = <Polyline>[];
          _getRoute();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: active ? color : scheme.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active ? color : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _arrivalTime(double seconds) {
    final DateTime t = DateTime.now().add(Duration(seconds: seconds.round()));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  void _applyModeRoute(String mode) {
    final RouteInfo? r = _routesByMode[mode];
    if (r == null) return;
    setState(() {
      _travelMode = mode;
      _route = r;
      _polylines = r.polyline.length >= 2
          ? <Polyline>[
              Polyline(
                points: r.polyline
                    .map((gm.LatLng lp) => LatLng(lp.latitude, lp.longitude))
                    .toList(),
                color: _modeColor(mode),
                strokeWidth: 5,
              ),
            ]
          : <Polyline>[];
    });
  }

  Widget _fastestRow() {
    String fastest = 'car';
    double fastestDur = double.infinity;
    _routesByMode.forEach((String m, RouteInfo r) {
      if (r.durationSeconds < fastestDur) {
        fastestDur = r.durationSeconds;
        fastest = m;
      }
    });
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final (String id, IconData icon, String label) in _modes)
          if (_routesByMode[id] != null)
            _modeTimeChip(id, icon, label,
                _routesByMode[id]!.durationSeconds, id == fastest),
      ],
    );
  }

  Widget _modeTimeChip(
    String mode,
    IconData icon,
    String label,
    double seconds,
    bool fastest,
  ) {
    final Color color = _modeColor(mode);
    final bool selected = _travelMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _applyModeRoute(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: selected ? color : Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              '${GeoUtils.formatDuration(seconds)}'
              '${fastest ? ' · fastest' : ''}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: fastest ? FontWeight.w800 : FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _resultsSheet() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: <BoxShadow>[
          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Search results',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _resultsVisible = false);
                  },
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(_searchError!,
                  style: TextStyle(color: scheme.error)),
            )
          else if (_results.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('No places found. Try a different search.',
                  style: Theme.of(context).textTheme.bodySmall),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _results.length,
                separatorBuilder: (BuildContext context, int i) =>
                    const Divider(height: 1),
                itemBuilder: (BuildContext context, int i) {
                  final Place p = _results[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      backgroundColor:
                          scheme.primaryContainer.withValues(alpha: 0.6),
                      child: Icon(Icons.place, color: scheme.primary),
                    ),
                    title: Text(p.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        if (p.address != null) p.address!,
                        if (_distanceTo(p.lat, p.lng) != null)
                          GeoUtils.formatDistance(_distanceTo(p.lat, p.lng)!),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _select(p),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => _setOriginFrom(p),
                          child: const Text('Start'),
                        ),
                        FilledButton(
                          onPressed: () => _select(p),
                          child: const Text('Go'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _permissionBanner() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.location_off, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Location is needed for GPS, distances and nearby places.',
              style:
                  TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: _enableLocation,
            child: Text(
              'Enable',
              style: TextStyle(
                  color: scheme.onErrorContainer,
                  fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tileNoticeBanner(String message) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.map_outlined, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectedSheet() {
    final Place p = _selected!;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final RouteInfo? r = _route;
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  p.name,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (_distanceToSelected != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    GeoUtils.formatDistance(_distanceToSelected!),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              ),
            ],
          ),
          if (p.address != null)
            Text(p.address!,
                style:
                    Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        )),
          const SizedBox(height: 12),
          // Google-style origin → destination summary.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.trip_origin,
                        size: 16, color: Color(0xFF16A34A)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _origin != null
                            ? (_originName ?? 'Start point')
                            : (_position == null
                                ? 'Map center (set your start)'
                                : 'My location'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: _toggleSetOrigin,
                      child: Text(_origin == null ? 'Set' : 'Change'),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 7),
                  child: SizedBox(
                    height: 12,
                    child: VerticalDivider(color: Colors.grey),
                  ),
                ),
                Row(
                  children: <Widget>[
                    const Icon(Icons.place, size: 18, color: Color(0xFFDC2626)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.swap_vert, size: 20),
                      tooltip: 'Swap start and destination',
                      onPressed: _swapOriginDestination,
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (r != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Icon(Icons.route, size: 18, color: _modeColor(_travelMode)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_modeLabel(_travelMode)} · '
                    '${GeoUtils.formatDistance(r.distanceMeters)} · '
                    '${GeoUtils.formatDuration(r.durationSeconds)} · '
                    'arrive ~${_arrivalTime(r.durationSeconds)}'
                    '${r.isApproximate ? ' (estimate)' : ''}',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (_comparingModes)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text('Comparing all modes…'),
                  ],
                ),
              )
            else if (_routesByMode.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _fastestRow(),
              ),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: PrimaryButton(
                  label: _routeLoading ? 'Calculating…' : 'Get route',
                  icon: _routeLoading ? null : Icons.directions,
                  loading: _routeLoading,
                  onPressed: _getRoute,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PrimaryButton(
                  label: 'Navigate',
                  icon: Icons.navigation,
                  outlined: true,
                  onPressed: _openNavigation,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
