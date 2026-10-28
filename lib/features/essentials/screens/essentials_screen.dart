import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/state/app_container.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/place_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/local/nearby_store.dart';
import '../../../data/models/places.dart';

/// Nearby essentials: on-demand nearby-POI search around the user's real GPS
/// location, with OpenStreetMap Overpass as the primary bulk engine and a
/// strict 25,000 m radius. Categories: Hospital, Police, Pharmacy, ATM, Fuel,
/// Food, Hotel, Transit, Attractions, Museums, Parks and Shopping — each with
/// its proper OSM tag mapping. Results are parsed, deduplicated, filtered to
/// the radius and sorted nearest-first; every result opens for details and
/// OSRM-based directions.
class EssentialsScreen extends StatefulWidget {
  const EssentialsScreen({super.key});

  @override
  State<EssentialsScreen> createState() => _EssentialsScreenState();
}

class _Category {
  const _Category(this.label, this.icon, this.categories);
  final String label;
  final IconData icon;

  /// Exact provider category keys used by the chip request. Each chip gets a
  /// category-scoped dataset so a hospital request cannot be filled with
  /// unrelated nearby places.
  final List<String> categories;
}

class _EssentialsScreenState extends State<EssentialsScreen> {
  AppContainer get _c => AppScope.of(context);

  static const List<_Category> _categories = <_Category>[
    _Category('Hospital', Icons.local_hospital, <String>['hospital']),
    _Category('Police', Icons.local_police, <String>['police']),
    _Category('Pharmacy', Icons.local_pharmacy, <String>['pharmacy']),
    _Category('ATM', Icons.local_atm, <String>['atm']),
    _Category('Fuel', Icons.local_gas_station, <String>['fuel']),
    _Category('Food', Icons.restaurant,
        <String>['food', 'restaurant', 'cafe', 'fast_food']),
    _Category('Hotel', Icons.hotel, <String>['hotel']),
    _Category('Transit', Icons.directions_bus, <String>['transit']),
    _Category('Attractions', Icons.attractions,
        <String>['tourist_attraction']),
    _Category('Museums', Icons.museum, <String>['museum']),
    _Category('Parks', Icons.park, <String>['park']),
    _Category('Shopping', Icons.shopping_bag, <String>['shopping']),
  ];

  Position? _position;
  bool _locationDone = false;
  _Category? _selected;
  List<Place> _results = const <Place>[];
  bool _loading = false;
  String? _error;
  String? _providerWarning;
  bool _stale = false;
  String? _datasetKey;
  StreamSubscription<NearbyUpdate>? _updatesSub;

  bool _subscribedUpdates = false;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe once: when a background refresh of the shown dataset lands,
    // swap the list in immediately and clear the saved-places banner (issue:
    // the banner used to stick around forever even with internet on).
    if (!_subscribedUpdates) {
      _subscribedUpdates = true;
      _updatesSub = _c.placesRepository.nearbyUpdates.listen(_onDatasetUpdate);
    }
  }

  void _onDatasetUpdate(NearbyUpdate u) {
    if (!mounted || _loading || _selected == null) return;
    if (u.key != _datasetKey || u.result.places.isEmpty) return;
    final List<Place> filtered = u.result.places
        .where((Place p) => _matches(p, _selected!.categories))
        .toList()
      ..sort((Place a, Place b) => (a.distanceMeters ?? double.infinity)
          .compareTo(b.distanceMeters ?? double.infinity));
    setState(() {
      _results = filtered;
      _providerWarning = _c.placesRepository.backendWarning;
      _stale = false;
    });
  }

  @override
  void dispose() {
    unawaited(_updatesSub?.cancel());
    super.dispose();
  }

  Future<void> _locate() async {
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted) return;
      setState(() {
        _position = pos;
        _locationDone = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _position = null;
          _locationDone = true;
        });
      }
    }
  }

  /// User-initiated retry: re-request permission (opening settings if it was
  /// denied/permanently denied) and re-obtain the fix. Never fabricates a
  /// coordinate — [currentPosition] returns null when nothing is available.
  Future<void> _retryLocation() async {
    try {
      final LocationPermission perm =
          await _c.locationService.ensurePermission();
      if (!mounted) return;
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        setState(() {
          _position = null;
          _locationDone = true;
        });
        return;
      }
    } catch (_) {}
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted) return;
      setState(() {
        _position = pos;
        _locationDone = true;
      });
    } catch (_) {
      if (mounted) setState(() => _position = null);
    }
  }

  Future<void> _search(_Category c, {Position? fixedPosition}) async {
    final int generation = ++_requestGeneration;
    // INSTANT FEEDBACK: the chip selects and the skeleton shows in the SAME
    // frame as the tap. The old flow awaited a fresh GPS fix BEFORE this
    // setState, so the button didn't even look tapped for seconds — the
    // reported "4 second delay on every option" bug.
    setState(() {
      _selected = c;
      _loading = true;
      _error = null;
      _providerWarning = null;
      _stale = false;
      _results = const <Place>[];
      _datasetKey = null;
    });
    // Position: a chip tap uses the fix the screen already holds (or the
    // best recent one — instant). Waiting for a fresh GPS lock belongs to
    // the explicit Refresh action, not to every tap.
    Position? pos = fixedPosition ?? _position;
    if (pos == null) {
      pos = await _fastPositionForSearch();
      if (!mounted || generation != _requestGeneration) return;
    }
    if (pos == null) {
      setState(() {
        _error =
            'Your location is unavailable. Turn on location services and retry.';
        _loading = false;
      });
      return;
    }
    if (!identical(pos, _position)) {
      setState(() => _position = pos);
    }
    try {
      // Cache-first (SWR): a repeat tap serves the cached dataset instantly
      // and refreshes in the background (the updates stream swaps the fresh
      // list in). Only the explicit Refresh button forces a network fetch.
      final NearbyResult dataset = await _loadDataset(c);
      if (!mounted || generation != _requestGeneration) return;
      final List<Place> filtered = dataset.places
          .where((Place p) => _matches(p, c.categories))
          .toList()
        ..sort((Place a, Place b) => (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
      setState(() {
        _results = filtered;
        _providerWarning = dataset.fromCache
            ? null
            : _c.placesRepository.backendWarning;
        _loading = false;
        _stale = dataset.stale;
        _datasetKey = dataset.key;
      });
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = _friendlyError(e);
        _loading = false;
      });
    }
    // Keep it LIVE: verify the position in the background; if the user has
    // actually moved well beyond the cached area, re-run this category at
    // the fresh fix (skipped for background re-runs to avoid loops).
    if (fixedPosition == null) {
      unawaited(_verifyLivePosition(c));
    }
  }

  /// Instant position for taps: the best recent fix without any GPS wait.
  Future<Position?> _fastPositionForSearch() async {
    final Position? recent = await _c.locationService.bestRecentFix();
    if (recent != null) return recent;
    // Nothing usable cached — only now wait for a live fix (hard-capped).
    try {
      return await _c.locationService
          .refreshPosition(timeout: const Duration(seconds: 10))
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return null;
    }
  }

  /// Background GPS verification after a tap-served list: fetches a fresh
  /// fix quietly; when the user has really moved (>500 m — beyond GPS
  /// jitter and half a cache bucket), the selected category re-runs around
  /// the live position so the list always follows where the user is.
  Future<void> _verifyLivePosition(_Category c) async {
    try {
      final Position? old = _position;
      final Position? fresh = await _c.locationService
          .refreshPosition(timeout: const Duration(seconds: 10))
          .timeout(const Duration(seconds: 12));
      if (!mounted || fresh == null || _selected != c) return;
      if (old != null) {
        final double moved = GeoUtils.distanceMeters(
          LatLng(old.latitude, old.longitude),
          LatLng(fresh.latitude, fresh.longitude),
        );
        if (moved < 500) return; // same area — the shown list is valid
      }
      await _search(c, fixedPosition: fresh);
    } catch (_) {
      // Verification is best-effort; the shown list stays as-is.
    }
  }

  Future<Position?> _freshPositionForSearch() async {
    Position? fresh;
    try {
      fresh = await _c.locationService
          .refreshPosition(timeout: const Duration(seconds: 10))
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      fresh = null;
    }
    // Cold GPS fallback: a recent known fix keeps Essentials usable (the
    // map already shows the live position in the same conditions).
    fresh ??= await _c.locationService.bestRecentFix();
    if (fresh != null && mounted) {
      setState(() {
        _position = fresh;
        _locationDone = true;
      });
    }
    return fresh;
  }

  String _providerCategory(_Category c) => switch (c.label) {
        'Hospital' => 'hospital',
        'Police' => 'police',
        'Pharmacy' => 'pharmacy',
        'ATM' => 'atm',
        'Fuel' => 'fuel',
        'Food' => 'food',
        'Hotel' => 'hotel',
        'Transit' => 'transit',
        'Attractions' => 'tourist_attraction',
        'Museums' => 'museum',
        'Parks' => 'park',
        'Shopping' => 'shopping',
        _ => c.label.toLowerCase(),
      };

  Future<NearbyResult> _loadDataset(
    _Category c, {
    bool force = false,
  }) {
    final Position pos = _position!;
    final LatLng here = LatLng(pos.latitude, pos.longitude);
    return _c.placesRepository.nearbyCategory(
      here,
      _providerCategory(c),
      force: force,
    );
  }

  /// Explicit Refresh: bypass the cache and force a fresh Overpass fetch.
  Future<void> _refresh() async {
    final int generation = ++_requestGeneration;
    final _Category? c = _selected;
    if (c == null) return;
    final Position? pos = await _freshPositionForSearch();
    if (!mounted || generation != _requestGeneration) return;
    if (pos == null) {
      setState(() {
        _error =
            'Could not get a fresh GPS fix. Turn on location services and retry.';
        _loading = false;
      });
      return;
    }
    setState(() {
      _position = pos;
      _loading = true;
      _error = null;
      _stale = false;
    });
    try {
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      final NearbyResult dataset = await _c.placesRepository.nearbyCategory(
        here,
        _providerCategory(c),
        force: true,
      );
      if (!mounted || generation != _requestGeneration) return;
      final List<Place> filtered = dataset.places
          .where((Place p) => _matches(p, c.categories))
          .toList()
        ..sort((Place a, Place b) => (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
      setState(() {
        _results = filtered;
        _providerWarning = dataset.fromCache
            ? null
            : _c.placesRepository.backendWarning;
        _loading = false;
        _stale = dataset.stale;
        _datasetKey = dataset.key;
      });
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = _friendlyError(e);
        _loading = false;
      });
    }
  }

  bool _matches(Place p, List<String> categories) {
    return categories
        .any((String c) => p.category == c || p.types.contains(c));
  }

  String _friendlyError(Object e) {
    if (e is ApiException) {
      return switch (e.kind) {
        // A provider timeout is not proof that the device is offline: mobile
        // data and map tiles can still work while an upstream is unavailable.
        ApiErrorKind.network ||
        ApiErrorKind.timeout =>
          'Nearby place providers could not be reached. Your connection may still be working; retry in a moment.',
        ApiErrorKind.rateLimited =>
          'Nearby places are temporarily unavailable. Try again shortly.',
        ApiErrorKind.server ||
        ApiErrorKind.upstream ||
        ApiErrorKind.parser =>
          'The nearby places service is unavailable right now. Please retry.',
        ApiErrorKind.unauthorized =>
          'The map/place service key was rejected. Please check the key and rebuild the app.',
        ApiErrorKind.location =>
          'Your location is currently unavailable.',
        _ => e.message,
      };
    }
    return 'Could not load nearby places. Please try again.';
  }

  String _distance(Place p) {
    if (p.distanceMeters != null) {
      return GeoUtils.formatDistance(p.distanceMeters!);
    }
    final Position? pos = _position;
    if (pos == null) return '';
    return GeoUtils.formatDistance(
      GeoUtils.distanceMeters(
        LatLng(pos.latitude, pos.longitude),
        p.coords,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby essentials'),
        actions: <Widget>[
          if (_selected != null && _position != null)
            IconButton(
              tooltip: 'Refresh nearby results',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : () => _refresh(),
            ),
        ],
      ),
      body: !_locationDone
          ? const LoadingView(message: 'Finding your location…')
          : Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final _Category c in _categories)
                        ChoiceChip(
                          avatar: Icon(c.icon, size: 16),
                          label: Text(c.label),
                          selected: _selected?.label == c.label,
                          onSelected: (_) => _search(c),
                        ),
                    ],
                  ),
                ),
                Expanded(child: _body()),
              ],
            ),
    );
  }

  Widget _body() {
    if (_selected == null) {
      // Distinguish "no location" from the plain empty prompt (requirement:
      // no-location / network / API-failure / zero-results must not blur).
      if (_position == null) {
        return ErrorState(
          message:
              "Your location isn't available yet. Turn on location services "
              'and allow location permission, then try again.',
          retryLabel: 'Enable location',
          onRetry: _retryLocation,
        );
      }
      return const EmptyState(
        icon: Icons.location_searching,
        title: 'What do you need nearby?',
        message:
            'Pick a category to search real places around your location. '
            'Results show distance, and each place opens for directions.',
      );
    }
    if (_loading) {
      return const LoadingView(message: 'Searching nearby…');
    }
    if (_error != null) {
      return ErrorState(
        message: _error!,
        onRetry: () => _search(_selected!),
      );
    }
    if (_providerWarning != null && _results.isEmpty) {
      return ErrorState(
        message: _providerWarning!,
        onRetry: () => _search(_selected!),
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'No nearby places found within 25 km.',
        message:
            'No ${_selected!.label.toLowerCase()} is mapped within 25 km of '
            'your location. Try another category or a larger town.',
        actionLabel: 'Retry',
        onAction: () => _refresh(),
      );
    }
    final bool hasWarning = _providerWarning != null;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _results.length + (_stale ? 1 : 0) + (hasWarning ? 1 : 0),
      itemBuilder: (BuildContext context, int i) {
        if (hasWarning && i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.info_outline,
                      size: 18, color: Color(0xFF9A5B00)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _providerWarning!,
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFF7A4A00)),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final int offset = hasWarning ? 1 : 0;
        final int contentIndex = i - offset;
        if (_stale && contentIndex == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.cloud_off, size: 16, color: Color(0xFFB26A00)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Showing saved places — updating to live results…',
                      style: TextStyle(
                          fontSize: 12.5, color: Color(0xFFB26A00)),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: const Color(0xFFB26A00),
                    ),
                    onPressed: _loading ? null : _refresh,
                    child: const Text('Refresh',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
            ),
          );
        }
        final Place p = _results[_stale ? contentIndex - 1 : contentIndex];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: PlaceCard(
            place: p,
            distance: _distance(p),
            onTap: () => context.push('/explore/place/${p.placeId}', extra: p),
          ),
        );
      },
    );
  }
}
