import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';

import '../../../core/app_config.dart';
import '../../../core/network/free_geo_client.dart';
import '../../../core/services/location_service.dart';
import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/places.dart';
import '../booking_models.dart';
import '../booking_service.dart';

/// 🚕 Ride booking — real GPS pickup, MapTiler destination search / map pin,
/// OSRM route preview, and hand-off to VERIFIED official provider flows
/// (Uber/Ola deep links with pickup+drop; Rapido official app without
/// prefill — honestly labelled). No fares, drivers or availability are ever
/// invented — those live in the provider's app.
class RideBookingScreen extends StatefulWidget {
  const RideBookingScreen({super.key});

  @override
  State<RideBookingScreen> createState() => _RideBookingScreenState();
}

class _RideBookingScreenState extends State<RideBookingScreen> {
  AppContainer get _c => AppScope.of(context);
  LocationService get _loc => _c.locationService;

  final TextEditingController _destText = TextEditingController();
  final MapController _mapController = MapController();

  ({String name, double lat, double lng})? _pickup;
  ({String name, double lat, double lng})? _drop;
  String _serviceType = 'cab'; // bike | auto | cab
  List<({String name, double lat, double lng})> _recents =
      const <({String name, double lat, double lng})>[];
  List<Place> _suggestions = const <Place>[];
  Position? _suggestFix; // GPS fix used for the current suggestions
  Timer? _debounce;
  bool _pickingOnMap = false;
  RouteInfo? _route;
  bool _routeLoading = false;
  String? _routeError;
  BookingProvider? _launching;

  @override
  void initState() {
    super.initState();
    _loadRecents();
    _useCurrentLocation();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _destText.dispose();
    super.dispose();
  }

  Future<void> _loadRecents() async {
    final List<({String name, double lat, double lng})> r =
        await _c.bookingService.recentLocations();
    if (mounted) setState(() => _recents = r);
  }

  Future<void> _useCurrentLocation() async {
    final Position? p = await _loc.currentPosition();
    if (!mounted) return;
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              '📍 Your current location is unavailable. Enable GPS and try again.')));
      return;
    }
    setState(() {
      _pickup = (
        name: 'Current location',
        lat: p.latitude,
        lng: p.longitude,
      );
    });
    _moveMap(LatLng(p.latitude, p.longitude));
    _refreshRoute();
  }

  void _moveMap(LatLng point) {
    try {
      _mapController.move(point, 14);
    } catch (_) {}
  }

  void _onDestQueryChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 3) {
      setState(() => _suggestions = const <Place>[]);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final Position? me = await _loc.currentPosition();
      try {
        final List<Place> places = await _c.placesRepository.suggest(
          q.trim(),
          location: me == null
              ? null
              : gm.LatLng(me.latitude, me.longitude),
          limit: 6,
        );
        if (!mounted) return;
        setState(() {
          _suggestFix = me;
          _suggestions = places;
        });
      } catch (_) {
        if (mounted) setState(() => _suggestions = const <Place>[]);
      }
    });
  }

  /// Contextual suggestion subtitle: " — Area, City · 3.2 km".
  String _subtitleFor(Place p) {
    final Position? me = _suggestFix;
    return PlaceRanking.subtitleFor(
        p, me == null ? null : gm.LatLng(me.latitude, me.longitude));
  }

  void _pickSuggestion(Place p) {
    setState(() {
      _drop = (name: p.name, lat: p.lat, lng: p.lng);
      _suggestions = const <Place>[];
      _destText.text = p.name;
    });
    _moveMap(LatLng(p.lat, p.lng));
    unawaited(_c.bookingService
        .addRecentLocation(p.name, p.lat, p.lng)
        .then((_) => _loadRecents()));
    _refreshRoute();
  }

  void _refreshRoute() {
    final ({String name, double lat, double lng})? from = _pickup;
    final ({String name, double lat, double lng})? to = _drop;
    if (from == null || to == null) return;
    setState(() {
      _routeLoading = true;
      _routeError = null;
    });
    _c.osrmClient
        .route(
      origin: gm.LatLng(from.lat, from.lng),
      destination: gm.LatLng(to.lat, to.lng),
      mode: _serviceType == 'bike' ? 'bike' : 'car',
    )
        .then((RouteInfo r) {
      if (!mounted) return;
      setState(() {
        _route = r;
        _routeLoading = false;
      });
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() {
        _route = null;
        _routeLoading = false;
        _routeError =
            'Fresh route information is temporarily unavailable. '
            'The ride provider will still receive your coordinates.';
      });
    });
  }

  Future<void> _openSummary(BookingProvider provider) async {
    if (_pickup == null || _drop == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Set both pickup and destination to continue.')));
      return;
    }
    final BookingQuery q = BookingQuery(
      fromName: _pickup!.name,
      fromLat: _pickup!.lat,
      fromLng: _pickup!.lng,
      toName: _drop!.name,
      toLat: _drop!.lat,
      toLng: _drop!.lng,
      serviceType: _serviceType,
    );
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('${provider.emoji} Continue with ${provider.providerName}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 10),
              _row('Pickup', _pickup!.name),
              _row('Destination', _drop!.name),
              _row('Service type', _serviceType),
              if (_route != null) ...<Widget>[
                _row(
                    'Route (OSRM, real)',
                    '${(_route!.distanceMeters / 1000).toStringAsFixed(1)} km · '
                        '~${(_route!.durationSeconds / 60).round()} min'),
              ],
              if (_route == null && _routeError != null)
                const Text('Route preview unavailable — the provider will '
                    'still get your coordinates.',
                    style: TextStyle(fontSize: 12, color: AppTheme.warning)),
              const SizedBox(height: 8),
              Text(provider.handoffNote,
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  label: Text('Continue with ${provider.providerName}'),
                  icon: const Icon(Icons.open_in_new, size: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((Object? confirmed) async {
      if (confirmed != true) return;
      await _launch(provider, q);
    });
  }

  Future<void> _launch(BookingProvider provider, BookingQuery q) async {
    setState(() => _launching = provider);
    final BookingLaunchResult result =
        await _c.bookingService.continueWithProvider(provider, q);
    if (!mounted) return;
    setState(() => _launching = null);
    final String message = switch (result) {
      BookingLaunchResult.opened =>
        '${provider.providerName} opened'
            '${provider.appSchemePrefillsLocation ? ' with your pickup & drop prefilled' : ''}. '
            'Complete the booking there — booking happens in ${provider.providerName}, not in Tourism.',
      BookingLaunchResult.openedApp =>
        'Official ${provider.providerName} app opened. Set your pickup & drop '
            'there — Tourism does not prefill them for this provider.',
      BookingLaunchResult.openedWeb =>
        'Official ${provider.providerName} website opened.',
      BookingLaunchResult.appNotInstalled =>
        'The ${provider.providerName} app is not installed — its official '
            'Play Store page was opened.',
      _ => describeLaunch(result),
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final List<BookingProvider> providers =
        BookingProviders.forCategory(BookingCategory.ride);
    return Scaffold(
      appBar: AppBar(title: const Text('🚕 Book a ride')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          _serviceTypeChips(),
          const SizedBox(height: 12),
          _pickupCard(),
          const SizedBox(height: 10),
          _destinationCard(),
          const SizedBox(height: 10),
          _mapCard(),
          if (_route != null || _routeError != null) ...<Widget>[
            const SizedBox(height: 10),
            _routeCard(),
          ],
          const SizedBox(height: 14),
          Text('Continue with a provider',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          for (final BookingProvider p in providers)
            _providerCard(p),
          const SizedBox(height: 10),
          Text(
            'Booking and payment happen in the provider\'s own app/site. '
            'Tourism never shows fares or availability — live prices come '
            'only from the provider.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text('TRAVEL-BOOKING-HUB-2026-09-14-01',
                style: TextStyle(fontSize: 10, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _serviceTypeChips() {
    return SegmentedButton<String>(
      segments: const <ButtonSegment<String>>[
        ButtonSegment<String>(value: 'bike', label: Text('🏍️ Bike')),
        ButtonSegment<String>(value: 'auto', label: Text('🛺 Auto')),
        ButtonSegment<String>(value: 'cab', label: Text('🚕 Cab')),
      ],
      selected: <String>{_serviceType},
      onSelectionChanged: (Set<String> s) {
        setState(() => _serviceType = s.first);
        _refreshRoute();
      },
    );
  }

  Widget _pickupCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.trip_origin, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _pickup == null
                        ? 'Pickup: getting your location…'
                        : 'Pickup: ${_pickup!.name}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Use current location',
                  onPressed: _useCurrentLocation,
                  icon: const Icon(Icons.my_location, size: 18),
                ),
              ],
            ),
            if (_pickup != null)
              Text(
                '${_pickup!.lat.toStringAsFixed(5)}, ${_pickup!.lng.toStringAsFixed(5)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  Widget _destinationCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _destText,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.location_on, size: 18),
                hintText: 'Where to? (MapTiler search)',
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: _pickingOnMap
                      ? 'Done picking on map'
                      : 'Pick on map',
                  icon: Icon(_pickingOnMap ? Icons.check : Icons.pin_drop,
                      size: 20),
                  onPressed: () => setState(() => _pickingOnMap = !_pickingOnMap),
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: _onDestQueryChanged,
            ),
            if (_drop != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Drop: ${_drop!.name}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            if (_suggestions.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              for (final Place p in _suggestions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place, size: 16),
                  title: Text(p.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text(_subtitleFor(p),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11)),
                  onTap: () => _pickSuggestion(p),
                ),
            ],
            if (_recents.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text('Recent',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final ({String name, double lat, double lng}) r
                      in _recents.take(4))
                    ActionChip(
                      label: Text(r.name,
                          style: const TextStyle(fontSize: 11)),
                      onPressed: () {
                        setState(() {
                          _drop = r;
                          _destText.text = r.name;
                        });
                        _moveMap(LatLng(r.lat, r.lng));
                        _refreshRoute();
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _mapCard() {
    final LatLng initial = _drop != null
        ? LatLng(_drop!.lat, _drop!.lng)
        : _pickup != null
            ? LatLng(_pickup!.lat, _pickup!.lng)
            : const LatLng(20.5937, 78.9629);
    return SizedBox(
      height: 220,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: <Widget>[
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: initial,
                initialZoom: _pickup == null && _drop == null ? 4 : 13,
                maxZoom: 19,
                onTap: (TapPosition _, LatLng point) {
                  if (!_pickingOnMap) return;
                  setState(() {
                    _drop = (
                      name: 'Map pin (${point.latitude.toStringAsFixed(4)}, '
                          '${point.longitude.toStringAsFixed(4)})',
                      lat: point.latitude,
                      lng: point.longitude,
                    );
                    _destText.text = _drop!.name;
                    _pickingOnMap = false;
                  });
                  _refreshRoute();
                },
              ),
              children: <Widget>[
                TileLayer(
                  urlTemplate: AppConfig.tileUrlTemplate('streets-v2'),
                  fallbackUrl: AppConfig.tileFallbackUrl,
                  userAgentPackageName: 'app.roamio.tourism',
                  retinaMode: RetinaMode.isHighDensity(context),
                  maxNativeZoom: 19,
                ),
                PolylineLayer(
                  polylines: <Polyline>[
                    if (_route != null && _route!.polyline.length >= 2)
                      Polyline(
                        points: _route!.polyline
                            .map((gm.LatLng p) =>
                                LatLng(p.latitude, p.longitude))
                            .toList(),
                        color: Theme.of(context).colorScheme.primary,
                        strokeWidth: 5,
                      ),
                  ],
                ),
                MarkerLayer(
                  markers: <Marker>[
                    if (_pickup != null)
                      Marker(
                        point: LatLng(_pickup!.lat, _pickup!.lng),
                        width: 28,
                        height: 28,
                        child: const Icon(Icons.trip_origin,
                            color: AppTheme.success, size: 26),
                      ),
                    if (_drop != null)
                      Marker(
                        point: LatLng(_drop!.lat, _drop!.lng),
                        width: 28,
                        height: 28,
                        child: const Icon(Icons.location_pin,
                            color: AppTheme.danger, size: 28),
                      ),
                  ],
                ),
              ],
            ),
            if (_pickingOnMap)
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Tap the map to set your destination pin',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _routeCard() {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _routeLoading
            ? const SizedBox(
                height: 20,
                child: LinearProgressIndicator())
            : _route != null
                ? Text(
                    'Route (real OSRM): '
                    '${(_route!.distanceMeters / 1000).toStringAsFixed(1)} km · '
                    '~${(_route!.durationSeconds / 60).round()} min by '
                    '${_serviceType == 'bike' ? 'bike' : 'car'}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  )
                : Text(_routeError ?? '',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.warning)),
      ),
    );
  }

  Widget _providerCard(BookingProvider p) {
    final bool busy = _launching?.providerId == p.providerId;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: busy ? null : () => _openSummary(p),
        leading: Text(p.emoji, style: const TextStyle(fontSize: 22)),
        title: Text(p.providerName,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          p.locationFormat == LocationFormat.latLng
              ? 'Pickup & drop passed to the official flow'
              : 'Opens the official app — set locations there',
          style: const TextStyle(fontSize: 11.5),
        ),
        trailing: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.chevron_right),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
                width: 110,
                child: Text(k,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}
