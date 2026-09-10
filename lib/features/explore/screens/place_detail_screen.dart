import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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
  const PlaceDetailScreen({super.key, required this.placeId});

  final String placeId;

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
  bool _photoLoading = false;
  bool _photoFailed = false;

  RouteInfo? _route;
  bool _routeLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
        _loadPositionAndPhoto();
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
    if (p != null && p.photoUrls.isNotEmpty) {
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
      } catch (_) {
        if (mounted) {
          setState(() {
            _photoLoading = false;
            _photoFailed = true;
          });
        }
      }
    }
  }

  Future<void> _loadRoute() async {
    final Position? pos = _position;
    final Place? p = _place;
    if (p == null) return;
    if (pos == null) {
      final LocationPermission perm =
          await _c.locationService.ensurePermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content:
                    Text('Location permission is required to get a route.')),
          );
        }
        return;
      }
      try {
        final Position? fixed = await _c.locationService.currentPosition();
        if (mounted) setState(() => _position = fixed);
      } catch (_) {}
      if (mounted && _position == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not get your current location.')),
        );
        return;
      }
    }
    if (mounted) setState(() => _routeLoading = true);
    try {
      final RouteInfo r = await _c.placesRepository.route(
        LatLng(_position!.latitude, _position!.longitude),
        p.coords,
      );
      if (mounted) {
        setState(() {
          _route = r;
          _routeLoading = false;
        });
        _showRouteSheet(r, p);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _routeLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get a route: $e')),
        );
      }
    }
  }

  void _showRouteSheet(RouteInfo r, Place p) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setSheet) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Route to ${p.name}',
                style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _stat(GeoUtils.formatDistance(r.distanceMeters),
                      r.isApproximate ? 'approx. distance' : 'distance'),
                  const SizedBox(width: 24),
                  _stat(
                      GeoUtils.formatDuration(r.durationSeconds),
                      r.isApproximate ? 'est. time' : 'travel time'),
                ],
              ),
              if (r.isApproximate)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Live routing is not available on your backend yet — '
                    'showing a straight-line estimate. Turn-by-turn '
                    'navigation opens in Google Maps.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'Open in Google Maps',
                icon: Icons.navigation,
                onPressed: () => _openNavigation(p),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
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
    context.go(
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
                              .withOpacity(0.14),
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
                        label: _routeLoading ? 'Getting route…' : 'Get route',
                        icon: _routeLoading ? null : Icons.route,
                        loading: _routeLoading,
                        onPressed: _loadRoute,
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
                          'Tip: “Get route” calculates the distance and travel '
                          'time, and “Open in Google Maps” starts real '
                          'turn-by-turn navigation on this device.',
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
        color: scheme.primaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _header(Place p, ColorScheme scheme) {
    return SizedBox(
      height: 190,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (_photoBytes != null)
            Image.memory(_photoBytes!, fit: BoxFit.cover)
          else
            Container(
              color: scheme.surfaceContainerHighest,
              child: Center(
                child: Icon(
                  PlaceCard.iconFor(p),
                  size: 64,
                  color: PlaceCard.colorFor(context, p).withOpacity(0.6),
                ),
              ),
            ),
          if (_photoLoading)
            Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Colors.transparent, Colors.black45],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
