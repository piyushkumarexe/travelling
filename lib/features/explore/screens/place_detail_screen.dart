import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_config.dart';
import '../../../core/network/osrm_client.dart';
import '../../../core/services/favorites_store.dart';
import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/place_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/places.dart';

/// Full place details: photo (via backend proxy), info, distance,
/// phone/website actions and real route + Google Maps navigation.
class PlaceDetailScreen extends StatefulWidget {
  const PlaceDetailScreen({super.key, required this.placeId, this.place});

  final String placeId;

  /// Full place passed from a list (Explore/Home) — used directly so the
  /// screen works even when the backend (details/ratings/photos) is offline.
  final Place? place;

  @override
  State<PlaceDetailScreen> createState() => _PlaceDetailScreenState();
}

class _PlaceDetailScreenState extends State<PlaceDetailScreen> {
  AppContainer get _c => AppScope.of(context);

  Place? _place;
  bool _loading = true;
  String? _error;

  Position? _position;
  Uint8List? _photoBytes;
  String? _imageUrl;
  String? _description;
  bool _photoLoading = false;
  bool _saved = false;

  bool _routeLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Place? preset = widget.place;
    if (preset != null) {
      setState(() {
        _place = preset;
        _loading = false;
      });
      unawaited(_loadPositionAndPhoto());
      unawaited(_initSaved());
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Place? p = await _c.placesRepository.details(widget.placeId);
      if (!mounted) return;
      setState(() {
        _place = p;
        _loading = false;
      });
      if (p != null) {
        unawaited(_loadPositionAndPhoto());
        unawaited(_initSaved());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadPositionAndPhoto() async {
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (mounted) setState(() => _position = pos);
    } catch (_) {}
    final Place? p = _place;
    if (p == null) return;
    // Backend photo first (real Google Places photo when backend is online).
    if (p.photoUrls.isNotEmpty) {
      if (mounted) setState(() => _photoLoading = true);
      try {
        final Uint8List bytes = await _c.placesRepository.photoBytes(
          p.photoUrls.first,
        );
        if (mounted) {
          setState(() {
            _photoBytes = bytes;
            _photoLoading = false;
          });
        }
        return;
      } catch (_) {
        if (mounted) setState(() => _photoLoading = false);
      }
    }
    // Free Wikipedia photo + description so OSM/Wikipedia places never show
    // a bare placeholder.
    String? image;
    String? extract;
    final String? title = _wikiTitleFromUrl(p.website);
    if (title != null) {
      final (String?, String?) s =
          await _c.placesRepository.wikipediaSummary(title);
      image = s.$1;
      extract = s.$2;
    }
    if (image == null && p.name.trim().isNotEmpty) {
      image = await _c.placesRepository.wikipediaThumbnailBySearch(p.name);
    }
    if (mounted) {
      setState(() {
        _imageUrl = image;
        _description = extract;
      });
    }
  }

  String? _wikiTitleFromUrl(String? url) {
    if (url == null) return null;
    final Uri? u = Uri.tryParse(url);
    if (u == null || !u.host.contains('wikipedia.org')) return null;
    final List<String> segs = u.pathSegments;
    if (segs.length >= 2 && segs.first == 'wiki') {
      return Uri.decodeComponent(segs[1]);
    }
    return null;
  }

  Future<void> _initSaved() async {
    final Place? p = _place;
    if (p == null) return;
    final bool saved = await FavoritesStore.contains(p.placeId);
    if (mounted) setState(() => _saved = saved);
  }

  Future<void> _toggleSaved() async {
    final Place? p = _place;
    if (p == null) return;
    final bool saved = await FavoritesStore.toggle(p);
    if (!mounted) return;
    setState(() => _saved = saved);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(saved
            ? 'Saved to your places.'
            : 'Removed from your saved places.'),
      ),
    );
  }

  /// "Get Directions": current GPS → destination via the free OSRM router,
  /// then draws the full road polyline on a map with distance + ETA. Every
  /// failure mode (permission denied, GPS unavailable, network, NoRoute /
  /// NoSegment, invalid coordinates) surfaces a specific message.
  Future<void> _getDirections() async {
    final Place? p = _place;
    if (p == null) return;

    // 1) Validate destination coordinates (never fabricate a route).
    if (!OsrmClient.validLatitude(p.lat) ||
        !OsrmClient.validLongitude(p.lng)) {
      _showDirectionsError(
        'This place has invalid coordinates, so a route can\'t be drawn.',
      );
      return;
    }

    // 2) Resolve the origin (current GPS) with proper permission handling.
    if (_position == null) {
      final LocationPermission perm =
          await _c.locationService.ensurePermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _showDirectionsError(
          'Location permission is required to get directions. Enable it in '
          'Settings, or open the map and set a start point.',
        );
        return;
      }
      try {
        final Position? fixed = await _c.locationService.currentPosition();
        if (mounted) setState(() => _position = fixed);
      } catch (_) {}
      if (_position == null) {
        _showDirectionsError(
          'GPS is unavailable. Turn on location services, or open the map '
          'and set a start point.',
        );
        return;
      }
    }

    // 3) Fetch the real road route from OSRM (keyless, no Google Routes).
    if (mounted) setState(() => _routeLoading = true);
    try {
      final RouteInfo r = await _c.placesRepository.osrmRoute(
        LatLng(_position!.latitude, _position!.longitude),
        p.coords,
      );
      if (!mounted) return;
      setState(() => _routeLoading = false);
      _showDirectionsSheet(r, p);
    } on OsrmException catch (e) {
      if (!mounted) return;
      setState(() => _routeLoading = false);
      _showDirectionsError(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _routeLoading = false);
      _showDirectionsError('Could not get a route: $e');
    }
  }

  void _showDirectionsError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showDirectionsSheet(RouteInfo r, Place p) {
    final LatLng origin = _position == null
        ? LatLng(r.polyline.first.latitude, r.polyline.first.longitude)
        : LatLng(_position!.latitude, _position!.longitude);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Directions to ${p.name}',
                      style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _stat(GeoUtils.formatDistance(r.distanceMeters), 'distance'),
                  const SizedBox(width: 28),
                  _stat(GeoUtils.formatDuration(r.durationSeconds),
                      'estimated travel time'),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: 240,
                  child: _DirectionsMap(
                    route: r,
                    origin: origin,
                    destination: p.coords,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Route drawn with free OSRM road routing from your location '
                'to ${p.name}.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: PrimaryButton(
                      label: 'Navigate',
                      icon: Icons.navigation,
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _openNavigation(p);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Full map',
                      icon: Icons.map,
                      outlined: true,
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _viewOnMap();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Column(
      children: <Widget>[
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Future<void> _openNavigation(Place p) async {
    // 1) Native Google Maps navigation (if the app is installed)
    final Uri nav = Uri.parse(
        'google.navigation:q=${p.lat},${p.lng}');
    if (await canLaunchUrl(nav)) {
      await launchUrl(nav, mode: LaunchMode.externalApplication);
      return;
    }
    // 2) Google Maps deep link (web/maps app)
    final Uri web = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=${p.lat},${p.lng}');
    if (await canLaunchUrl(web)) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
      return;
    }
    // 3) geo URI last resort
    final Uri geo = Uri.parse('geo:0,0?dlat=${p.lat}&dlng=${p.lng}');
    if (await canLaunchUrl(geo)) {
      await launchUrl(geo, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No maps application found on this device.')),
      );
    }
  }

  Future<void> _call(String phone) async {
    final Uri uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This device cannot place calls.')),
      );
    }
  }

  Future<void> _openWebsite(String url) async {
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _viewOnMap() {
    final Place? p = _place;
    if (p == null) return;
    context.push(
      '/map?lat=${p.lat}&lng=${p.lng}&name=${Uri.encodeComponent(p.name)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Place')),
        body: const LoadingView(message: 'Loading place details…'),
      );
    }
    if (_error != null || _place == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Place')),
        body: ErrorState(
          message: _error ?? 'Place not found.',
          onRetry: _load,
        ),
      );
    }
    final Place p = _place!;
    final String? distance = _position == null
        ? null
        : GeoUtils.formatDistance(GeoUtils.distanceMeters(
            LatLng(_position!.latitude, _position!.longitude), p.coords));

    return Scaffold(
      appBar: AppBar(title: const Text('Place details')),
      body: ListView(
        children: <Widget>[
          _header(p, scheme),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        p.name,
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (p.openNow != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: (p.openNow! ? AppTheme.success : AppTheme.danger)
                              .withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          p.openNow! ? 'Open now' : 'Closed',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: p.openNow! ? AppTheme.success : AppTheme.danger,
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: _saved ? 'Remove from saved' : 'Save place',
                      icon: Icon(
                        _saved ? Icons.bookmark : Icons.bookmark_border,
                        color: _saved ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      onPressed: _toggleSaved,
                    ),
                  ],
                ),
                if (p.address != null && p.address!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Icon(Icons.place, size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(p.address!,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ],
                if (_description != null && _description!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    _description!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: <Widget>[
                    if (p.rating != null)
                      _chip('★ ${p.rating!.toStringAsFixed(1)}'
                          '${p.userRatingCount != null ? ' (${p.userRatingCount})' : ''}'),
                    if (distance != null) _chip(distance),
                    if (p.primaryType != null && p.primaryType!.isNotEmpty)
                      _chip(p.primaryType!.replaceAll('_', ' ')),
                    if (p.priceLevel != null) _chip('Price: \$${p.priceLevel}'),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                      Expanded(
                        child: PrimaryButton(
                          label: _routeLoading
                              ? 'Getting directions…'
                              : 'Get Directions',
                          icon: _routeLoading ? null : Icons.directions,
                          loading: _routeLoading,
                          onPressed: _getDirections,
                        ),
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: PrimaryButton(
                        label: 'View on map',
                        icon: Icons.map,
                        outlined: true,
                        onPressed: _viewOnMap,
                      ),
                    ),
                  ],
                ),
                if (p.phone != null && p.phone!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(Icons.call),
                        onPressed: () => _call(p.phone!),
                      ),
                      Expanded(
                          child: Text(p.phone!,
                              style: Theme.of(context).textTheme.bodyMedium)),
                    ],
                  ),
                ],
                if (p.website != null && p.website!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      IconButton(
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () => _openWebsite(p.website!)),
                      Expanded(
                          child: Text(p.website!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium)),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                AppCard(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.info_outline,
                          size: 18, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Tip: “Get Directions” draws the real road route '
                          '(free OSRM routing, no API key) with distance and '
                          'travel time, and “Navigate” starts turn-by-turn '
                          'navigation on this device.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _header(Place p, ColorScheme scheme) {
    final Widget image;
    if (_photoBytes != null) {
      image = Image.memory(_photoBytes!, fit: BoxFit.cover);
    } else if (_imageUrl != null) {
      image = Image.network(
        _imageUrl!,
        fit: BoxFit.cover,
        loadingBuilder: (BuildContext context, Widget child,
            ImageChunkEvent? progress) {
          if (progress == null) return child;
          return ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: const Center(child: CircularProgressIndicator()),
          );
        },
        errorBuilder: (BuildContext context, Object e, StackTrace? s) =>
            _placeholder(p, scheme),
      );
    } else {
      image = _placeholder(p, scheme);
    }
    return SizedBox(
      height: 210,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          image,
          if (_photoLoading)
            ColoredBox(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _placeholder(Place p, ColorScheme scheme) {
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          PlaceCard.iconFor(p),
          size: 64,
          color: PlaceCard.colorFor(context, p).withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

/// Small map that renders the OSRM route polyline between the origin and the
/// destination, with both endpoints pinned.
class _DirectionsMap extends StatelessWidget {
  const _DirectionsMap({
    required this.route,
    required this.origin,
    required this.destination,
  });

  final RouteInfo route;

  /// google_maps_flutter [LatLng] of the start point.
  final LatLng origin;

  /// google_maps_flutter [LatLng] of the destination.
  final LatLng destination;

  @override
  Widget build(BuildContext context) {
    final List<ll.LatLng> pts = route.polyline
        .map((LatLng lp) => ll.LatLng(lp.latitude, lp.longitude))
        .toList();
    // Fit the camera over the whole route manually (latlong2 0.9 has no
    // LatLngBounds), so the preview shows origin, route and destination.
    final List<ll.LatLng> all = <ll.LatLng>[
      ll.LatLng(origin.latitude, origin.longitude),
      ...pts,
    ];
    double minLat = all.first.latitude;
    double maxLat = all.first.latitude;
    double minLng = all.first.longitude;
    double maxLng = all.first.longitude;
    for (final ll.LatLng p in all) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final ll.LatLng center =
        ll.LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    final double span =
        math.max((maxLat - minLat).abs(), (maxLng - minLng).abs());
    return fm.FlutterMap(
      options: fm.MapOptions(
        initialCenter: center,
        initialZoom: _zoomForSpan(span),
      ),
      children: <Widget>[
        fm.TileLayer(
          urlTemplate: AppConfig.tileUrlTemplate('streets-v2'),
          fallbackUrl: AppConfig.tileFallbackUrl,
          userAgentPackageName: 'app.roamio.tourism',
        ),
        fm.PolylineLayer(
          polylines: <fm.Polyline>[
            fm.Polyline(
              points: pts,
              color: const Color(0xFF2563EB),
              strokeWidth: 5,
            ),
          ],
        ),
        fm.MarkerLayer(
          markers: <fm.Marker>[
            fm.Marker(
              point: ll.LatLng(origin.latitude, origin.longitude),
              width: 30,
              height: 30,
              child: const Icon(Icons.trip_origin,
                  color: Color(0xFF16A34A), size: 30),
            ),
            fm.Marker(
              point: ll.LatLng(destination.latitude, destination.longitude),
              width: 36,
              height: 36,
              child: const Icon(Icons.location_pin,
                  color: Color(0xFFDC2626), size: 36),
            ),
          ],
        ),
      ],
    );
  }

  double _zoomForSpan(double span) {
    if (span > 20) return 4;
    if (span > 8) return 5;
    if (span > 4) return 6;
    if (span > 2) return 7;
    if (span > 1) return 8;
    if (span > 0.5) return 9;
    if (span > 0.2) return 10;
    if (span > 0.1) return 11;
    if (span > 0.05) return 12;
    return 13;
  }
}
