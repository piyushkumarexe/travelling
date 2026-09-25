import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/osrm_client.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/geo.dart';
import '../../data/local/nearby_store.dart';
import '../../data/models/places.dart';
import '../../data/repositories/places_repository.dart';
import 'autopilot_engine.dart';
import 'autopilot_models.dart';

/// TRAVEL AUTOPILOT — session state.
///
/// Reuses the app's real systems only:
/// - LocationService for GPS (never a fake/default location)
/// - PlacesRepository.nearbyAround (cached Overpass dataset + SWR refresh)
/// - OsrmClient for REAL road travel times (table + route)
/// - SharedPreferences for session persistence (survives app restarts)
///
/// No new network stack, no second location system, no invented data.
class AutopilotService extends ChangeNotifier {
  AutopilotService({
    required PlacesRepository placesRepository,
    required LocationService locationService,
    OsrmClient? osrm,
  })  : _places = placesRepository,
        _location = locationService,
        _osrm = osrm ?? OsrmClient() {
    // Silent live refresh: when the background dataset refresh lands,
    // re-rank with fresh data (matches the app's stale-while-revalidate UX).
    _updatesSub = _places.nearbyUpdates.listen((NearbyUpdate u) {
      if (u.key == _datasetKey && !_loading) {
        _dataset = u.result.places;
        unawaited(recompute());
      }
    });
  }

  bool _restored = false;

  /// Idempotent: loads a persisted session (called when the UI first opens;
  /// the uid provider must be wired before this point).
  Future<void> ensureRestored() async {
    if (_restored) return;
    _restored = true;
    await _restore();
  }

  final PlacesRepository _places;
  final LocationService _location;
  final OsrmClient _osrm;

  StreamSubscription<NearbyUpdate>? _updatesSub;
  StreamSubscription<Position>? _arrivalSub;

  // ── live tracking ────────────────────────────────────────────────────────
  // The other half of Autopilot: not only "what should I do now" but "where
  // are you right now, and where did the plan expect you at this minute".
  // Every GPS fix while a stop is in progress updates these, and the status
  // card reads them (distance to the stop, GPS age, behind-plan minutes).
  double? _liveDistanceMeters;
  double? _livePrevDistanceMeters;
  DateTime? _liveFixAt;
  bool _liveMovingAway = false;
  Timer? _liveTicker;

  // --- Session state ---
  AutopilotSession? _session;
  AutopilotBrief _brief = const AutopilotBrief();
  List<Place> _dataset = const <Place>[];
  String? _datasetKey;
  List<AutopilotSuggestion> _suggestions = const <AutopilotSuggestion>[];
  List<(AutopilotSuggestion, String)> _notPractical =
      const <(AutopilotSuggestion, String)>[];
  AutopilotPlan? _plan;
  AutopilotRecovery? _recovery;

  bool _loading = false;
  AutopilotErrorKind? _error;
  String? _errorMessage;
  LatLng? _lastHere;

  /// Resolved destination name (null when exploring around the current
  /// position only).
  String? get destinationName {
    final String? n = _brief.endName;
    return (n != null && n.trim().isNotEmpty) ? n.trim() : null;
  }

  /// Session interest learning: category → accepted/visited count.
  final Map<String, int> _learned = <String, int>{};

  /// Real OSRM travel minutes by placeId for the current candidate set.
  Map<String, int> _realTravel = const <String, int>{};
  final Map<String, int> _routeCache = <String, int>{};

  // --- Developer-only simulation (never shown in normal production UI) ---
  Duration _debugTimeOffset = Duration.zero;
  LatLng? _debugPosition;
  bool debugUnlocked = false;

  // ---------------- Getters ----------------
  AutopilotSession? get session => _session;
  AutopilotBrief get brief => _brief;
  List<AutopilotSuggestion> get suggestions => _suggestions;
  List<(AutopilotSuggestion, String)> get notPractical => _notPractical;
  AutopilotPlan? get plan => _plan;
  AutopilotRecovery? get recovery => _recovery;
  bool get loading => _loading;
  AutopilotErrorKind? get error => _error;
  String? get errorMessage => _errorMessage;
  LatLng? get lastHere => _debugPosition ?? _lastHere;
  Map<String, int> get learnedInterest => Map<String, int>.unmodifiable(_learned);

  DateTime now() => DateTime.now().add(_debugTimeOffset);

  int minutesLeft() {
    final AutopilotSession? s = _session;
    if (s == null) return _brief.availableMinutes ?? 120;
    return s.leftFrom(now()).inMinutes;
  }

  AutopilotStop? get currentStop => _session?.currentStop;

  // ---------------- Location ----------------
  Future<LatLng?> _here() async {
    if (_debugPosition != null) return _debugPosition;
    // Explicit accuracy path first (never a stale cache) — the dataset
    // centre must follow the traveller's REAL position. Falls back to the
    // fast last-known fix so a slow cold start still gets results.
    Position? p;
    try {
      p = await _location.refreshPosition(timeout: const Duration(seconds: 8));
    } catch (_) {
      p = null;
    }
    if (p == null) {
      try {
        p = await _location.lastKnown();
      } catch (_) {
        p = null;
      }
    }
    if (p == null) return null;
    _lastHere = LatLng(p.latitude, p.longitude);
    return _lastHere;
  }

  // ---------------- Destination (end point) ----------------
  /// True while the traveller has effectively arrived at the selected
  /// destination (dataset then follows the live position as usual).
  bool _atDestination = false;
  double _destinationDistanceMeters = 0;

  /// Distance from the current position to the selected destination (0 when
  /// none / already there) — surfaced in the UI.
  double get destinationDistanceMeters => _destinationDistanceMeters;
  bool get atDestination => _atDestination;

  /// Resolves a destination the traveller asked for: the explicit "End
  /// destination" field, or a place named inside the free-text request
  /// ("I want to explore Ayodhya"). Geocoding uses the existing
  /// PlacesRepository — no second network stack. Major Indian destinations
  /// also have a bundled city-centre geocode so an explicit request remains
  /// usable when public geocoders are temporarily blocked on mobile data.
  /// Unknown destinations remain unresolved and are rejected by [start]; they
  /// must NEVER silently turn into a plan around the current GPS position.
  Future<AutopilotBrief> _resolveDestination(AutopilotBrief brief) async {
    if (brief.endLat != null && brief.endLng != null) return brief;
    String? name = brief.endName;
    if ((name == null || name.trim().isEmpty) && brief.freeText != null) {
      name = AutopilotEngine.destinationCandidate(brief.freeText!);
    }
    final String q = (name ?? '').trim();
    if (q.length < 3) return brief;

    final ({String name, double lat, double lng})? known =
        bundledDestination(q);
    if (known != null) {
      return brief.copyWith(
        endName: known.name,
        endLat: known.lat,
        endLng: known.lng,
      );
    }
    try {
      final List<Place> found = await _places
          // This is an explicitly named destination, not a “near me” search.
          // Passing the current GPS fix made the relevance filter discard a
          // distant city such as Mumbai before Autopilot could plan around it.
          .search(q, location: null, biasToUserLocation: false)
          // Must outlast the providers' own budgets (Overpass needs up to
          // 22 s) — cutting it at 12 s silently dropped a destination the
          // traveller typed ("explore Ayodhya") instead of resolving it.
          .timeout(const Duration(seconds: 24));
      if (found.isEmpty) return brief;
      final Place d = found.first;
      // Keep the resolved coordinates even when the traveller is already in
      // that city. The downstream centre selection knows how to follow live
      // GPS on arrival; dropping them here would make an explicit destination
      // indistinguishable from a failed lookup.
      return brief.copyWith(endName: d.name, endLat: d.lat, endLng: d.lng);
    } catch (_) {
      return brief;
    }
  }

  /// Stable city-centre geocodes for common Indian travel destinations.
  /// These are destination centres, not invented attractions or businesses;
  /// live nearby providers still supply every suggested place around them.
  @visibleForTesting
  static ({String name, double lat, double lng})? bundledDestination(
      String query) {
    final String q = query
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9, ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const Map<String, ({String name, double lat, double lng})> cities =
        <String, ({String name, double lat, double lng})>{
      'ayodhya': (name: 'Ayodhya', lat: 26.7922, lng: 82.1998),
      'lucknow': (name: 'Lucknow', lat: 26.8467, lng: 80.9462),
      'mumbai': (name: 'Mumbai', lat: 19.0760, lng: 72.8777),
      'new delhi': (name: 'New Delhi', lat: 28.6139, lng: 77.2090),
      'delhi': (name: 'Delhi', lat: 28.6139, lng: 77.2090),
      'agra': (name: 'Agra', lat: 27.1767, lng: 78.0081),
      'varanasi': (name: 'Varanasi', lat: 25.3176, lng: 82.9739),
      'prayagraj': (name: 'Prayagraj', lat: 25.4358, lng: 81.8463),
      'allahabad': (name: 'Prayagraj', lat: 25.4358, lng: 81.8463),
      'jaipur': (name: 'Jaipur', lat: 26.9124, lng: 75.7873),
      'udaipur': (name: 'Udaipur', lat: 24.5854, lng: 73.7125),
      'amritsar': (name: 'Amritsar', lat: 31.6340, lng: 74.8723),
      'haridwar': (name: 'Haridwar', lat: 29.9457, lng: 78.1642),
      'rishikesh': (name: 'Rishikesh', lat: 30.0869, lng: 78.2676),
      'shimla': (name: 'Shimla', lat: 31.1048, lng: 77.1734),
      'manali': (name: 'Manali', lat: 32.2432, lng: 77.1892),
      'srinagar': (name: 'Srinagar', lat: 34.0837, lng: 74.7973),
      'kolkata': (name: 'Kolkata', lat: 22.5726, lng: 88.3639),
      'chennai': (name: 'Chennai', lat: 13.0827, lng: 80.2707),
      'hyderabad': (name: 'Hyderabad', lat: 17.3850, lng: 78.4867),
      'bengaluru': (name: 'Bengaluru', lat: 12.9716, lng: 77.5946),
      'bangalore': (name: 'Bengaluru', lat: 12.9716, lng: 77.5946),
      'kochi': (name: 'Kochi', lat: 9.9312, lng: 76.2673),
      'pune': (name: 'Pune', lat: 18.5204, lng: 73.8567),
      'panaji': (name: 'Panaji', lat: 15.4909, lng: 73.8278),
      'goa': (name: 'Goa', lat: 15.4909, lng: 73.8278),
      'mathura': (name: 'Mathura', lat: 27.4924, lng: 77.6737),
      'vrindavan': (name: 'Vrindavan', lat: 27.5650, lng: 77.6593),
    };
    final ({String name, double lat, double lng})? exact = cities[q];
    if (exact != null) return exact;
    for (final MapEntry<String, ({String name, double lat, double lng})> e
        in cities.entries) {
      if (q.startsWith('${e.key},') || q.startsWith('${e.key} ')) {
        return e.value;
      }
    }
    return null;
  }

  /// Small verified fallback directory for destinations where the public POI
  /// providers are all unreachable. Records are real, stable landmarks with
  /// sourced coordinates; live/cache results always take precedence.
  @visibleForTesting
  static List<Place> bundledDestinationPlaces(String? destinationName) {
    if (destinationName?.trim().toLowerCase() != 'ayodhya') {
      return const <Place>[];
    }
    return <Place>[
      Place(
        placeId: 'bundled:ayodhya:ram-mandir',
        name: 'Shri Ram Janmabhoomi Mandir',
        lat: 26.7956,
        lng: 82.1943,
        primaryType: 'tourist_attraction',
        types: const <String>['tourist_attraction', 'hindu_temple'],
        category: 'attraction',
        provider: 'bundled_directory',
        city: 'Ayodhya',
        state: 'Uttar Pradesh',
      ),
      Place(
        placeId: 'bundled:ayodhya:hanuman-garhi',
        name: 'Hanuman Garhi',
        lat: 26.7952876,
        lng: 82.2016429,
        primaryType: 'tourist_attraction',
        types: const <String>['tourist_attraction', 'hindu_temple'],
        category: 'attraction',
        provider: 'bundled_directory',
        city: 'Ayodhya',
        state: 'Uttar Pradesh',
      ),
      Place(
        placeId: 'bundled:ayodhya:kanak-bhawan',
        name: 'Kanak Bhawan',
        lat: 26.7984517,
        lng: 82.1992995,
        primaryType: 'tourist_attraction',
        types: const <String>['tourist_attraction', 'hindu_temple'],
        category: 'attraction',
        provider: 'bundled_directory',
        city: 'Ayodhya',
        state: 'Uttar Pradesh',
      ),
    ];
  }

  /// Whether a requested named destination failed to acquire coordinates.
  /// Kept pure so the no-silent-GPS-fallback safety contract is regression
  /// tested without needing a live geocoder or GPS.
  @visibleForTesting
  static bool hasUnresolvedExplicitDestination(
    AutopilotBrief requested,
    AutopilotBrief resolved,
  ) {
    String? name = requested.endName;
    if ((name == null || name.trim().isEmpty) && requested.freeText != null) {
      name = AutopilotEngine.destinationCandidate(requested.freeText!);
    }
    return (name ?? '').trim().length >= 3 &&
        (resolved.endLat == null || resolved.endLng == null);
  }

  // ---------------- Persistence ----------------
  static const String _sessionPrefix = 'autopilot.session.v1.';
  static const String _learnPrefix = 'autopilot.learn.v1.';

  String? _uid() => _authUid?.call();
  String? Function()? _authUid;

  /// Wires the user id provider (called once from AppContainer setup).
  set uidProvider(String? Function() provider) => _authUid = provider;

  Future<void> _save() async {
    final String? uid = _uid();
    if (uid == null) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final AutopilotSession? s = _session;
      if (s == null) {
        await prefs.remove('$_sessionPrefix$uid');
      } else {
        await prefs.setString('$_sessionPrefix$uid', s.encode());
      }
      await prefs.setString('$_learnPrefix$uid', jsonEncode(_learned));
    } catch (_) {
      // Persistence is best-effort.
    }
  }

  Future<void> _restore() async {
    final String? uid = _uid();
    if (uid == null) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('$_sessionPrefix$uid');
      if (raw != null) {
        final AutopilotSession s = AutopilotSession.decode(raw);
        if (s.endsAt.isAfter(now()) &&
            s.stops.any((AutopilotStop st) =>
                st.status == AutopilotStopStatus.accepted ||
                st.status == AutopilotStopStatus.visited ||
                st.status == AutopilotStopStatus.proposed)) {
          _session = s;
          _brief = s.brief;
          unawaited(recompute());
          _watchArrival();
          notifyListeners();
        } else {
          await prefs.remove('$_sessionPrefix$uid');
        }
      }
      final String? learn = prefs.getString('$_learnPrefix$uid');
      if (learn != null) {
        // Lightweight decode of {"cat":n,...}.
        final RegExp pair = RegExp(r'"([^"]+)":(\d+)');
        for (final RegExpMatch m in pair.allMatches(learn)) {
          _learned[m.group(1)!] = int.parse(m.group(2)!);
        }
      }
    } catch (_) {
      // Corrupt session → ignore, start fresh.
    }
  }

  // ---------------- Flow: start ----------------

  /// The one allowed construction path for an explicit Generate action.
  /// Keeping this pure makes the no-history/no-old-deadline contract directly
  /// testable without a GPS or place-provider fake.
  @visibleForTesting
  static AutopilotSession freshSessionForGenerate(
    AutopilotBrief brief,
    DateTime now, {
    String? id,
  }) =>
      AutopilotSession(
        id: id ?? 'ap-${now.millisecondsSinceEpoch}',
        brief: brief,
        startedAt: now,
        endsAt: now.add(Duration(minutes: brief.availableMinutes ?? 120)),
        stops: const <AutopilotStop>[],
      );

  /// "What do you want to do?" → time → [GENERATE].
  /// Works with ZERO itinerary: only location (+ optional time) required.
  ///
  /// A destination ("End destination" field or a place named in the free
  /// text, e.g. "I want to explore Ayodhya") is geocoded FIRST: while the
  /// traveller is still far from it, suggestions come from THAT place —
  /// not from whatever street the GPS happens to be on.
  Future<bool> start(AutopilotBrief brief) async {
    _loading = true;
    _error = null;
    _errorMessage = null;
    _plan = null;
    _recovery = null;
    _suggestions = const <AutopilotSuggestion>[];
    _notPractical = const <(AutopilotSuggestion, String)>[];
    _dataset = const <Place>[];
    _datasetKey = null;
    _realTravel = const <String, int>{};
    notifyListeners();
    String? requestedDestination = brief.endName;
    if ((requestedDestination == null || requestedDestination.trim().isEmpty) &&
        brief.freeText != null) {
      requestedDestination =
          AutopilotEngine.destinationCandidate(brief.freeText!);
    }
    _brief = await _resolveDestination(brief);
    if (hasUnresolvedExplicitDestination(brief, _brief)) {
      _loading = false;
      _error = AutopilotErrorKind.noResults;
      _errorMessage =
          'Could not locate "${requestedDestination!.trim()}". Check the spelling or add the state/country, then try again. No nearby plan was substituted.';
      notifyListeners();
      return false;
    }
    // A session exists from the first GENERATE whether or not the traveller
    // filled in "available time": the live monitor (where you are vs where the
    // plan expects you) is driven by the session, and tying it to an optional
    // field meant that leaving the field blank gave suggestions with no
    // tracking at all.
    // GENERATE means a NEW plan. `??=` reused a persisted session, including
    // all its visited/skipped place IDs and old deadline; the next run then
    // filtered every fresh result as "already visited" and showed the exact
    // false empty state reported on-device. Resume happens on screen load —
    // explicit Generate must always reset plan history and the clock.
    _session = freshSessionForGenerate(_brief, now());
    notifyListeners();
    return recompute();
  }

  /// Core engine run: location → (destination?) → cached dataset → rank →
  /// (real OSRM times).
  ///
  /// Dataset centre: the SELECTED DESTINATION while the traveller is still
  /// more than 25 km from it (planning a trip to e.g. Ayodhya — suggestions
  /// must come from Ayodhya, not from the current street); once within 25 km
  /// (arrived / on the way's last leg) the live position takes over.
  Future<bool> recompute() async {
    _loading = true;
    _error = null;
    _errorMessage = null;
    notifyListeners();
    try {
      final LatLng? here = await _here();
      if (here == null) {
        _loading = false;
        _error = AutopilotErrorKind.locationUnavailable;
        _errorMessage = 'Your current location is unavailable.';
        notifyListeners();
        return false;
      }
      final double? endLat = _brief.endLat;
      final double? endLng = _brief.endLng;
      final LatLng? dest = (endLat != null && endLng != null)
          ? LatLng(endLat, endLng)
          : null;
      final double destDist = dest == null
          ? 0
          : GeoUtils.distanceMeters(here, dest);
      _atDestination = dest == null || destDist <= 25000;
      _destinationDistanceMeters = destDist;
      final LatLng center = _atDestination ? here : dest!;
      _center = center;
      final String? originLabel = _atDestination
          ? null
          : 'from ${(_brief.endName ?? 'destination').trim()}';
      // Cached dataset (instant when available; SWR refresh lands later).
      // A provider outage or a city with nothing cached yet used to kill the
      // whole GENERATE tap with "no suitable places found nearby" — the
      // traveller was left with an empty screen and no plan. Sweep the
      // providers for the traveller's own interests instead and rank
      // whatever answers; only a genuinely empty area is reported as empty.
      NearbyResult? near;
      Object? nearbyError;
      try {
        near = await _places.nearbyAround(center, force: _dataset.isEmpty);
      } catch (e) {
        nearbyError = e;
        // Providers down / cache empty — the wide sweep below takes over.
      }
      _dataset = near?.places ?? const <Place>[];
      _datasetKey = near?.key;
      if (_dataset.isEmpty) {
        try {
          _dataset =
              await _wideSweep(center).timeout(const Duration(seconds: 45));
        } catch (_) {
          // Timeout or total outage — reported as an empty area below.
        }
      }
      if (_dataset.isEmpty) {
        _dataset = bundledDestinationPlaces(_brief.endName);
        if (_dataset.isNotEmpty) {
          _datasetKey = 'bundled:${_brief.endName!.toLowerCase()}';
        }
      }
      if (_dataset.isEmpty) {
        final Object? failed = nearbyError;
        _loading = false;
        if (failed is ApiException) {
          // The sweep ran and the providers answered with an error (or
          // nothing at all) — say so, instead of implying the area is empty.
          _error = switch (failed.kind) {
            ApiErrorKind.rateLimited => AutopilotErrorKind.rateLimited,
            ApiErrorKind.network ||
            ApiErrorKind.timeout =>
              AutopilotErrorKind.networkError,
            _ => AutopilotErrorKind.invalidData,
          };
          _errorMessage = switch (_error!) {
            AutopilotErrorKind.rateLimited =>
              'Nearby search is temporarily limited. Try again shortly.',
            AutopilotErrorKind.networkError =>
              'Fresh nearby information is temporarily unavailable. '
                  'Check your internet connection and retry.',
            _ => 'Could not load nearby places right now.',
          };
        } else {
          _error = AutopilotErrorKind.noResults;
          _errorMessage = _atDestination
              ? 'No suitable places found nearby.'
              : 'No suitable places found near '
                  '${(_brief.endName ?? 'your destination').trim()}.';
        }
        notifyListeners();
        return false;
      }
      _rank(center, originLabel: originLabel);
      _loading = false;
      notifyListeners();
      // Progressive: upgrade estimates to real OSRM times in one request.
      unawaited(_upgradeWithRealRoutes(center));
      return true;
    } on ApiException catch (e) {
      _loading = false;
      _error = switch (e.kind) {
        ApiErrorKind.rateLimited => AutopilotErrorKind.rateLimited,
        ApiErrorKind.network ||
        ApiErrorKind.timeout =>
          AutopilotErrorKind.networkError,
        _ => AutopilotErrorKind.invalidData,
      };
      _errorMessage = switch (_error!) {
        AutopilotErrorKind.rateLimited =>
          'Nearby search is temporarily limited. Try again shortly.',
        AutopilotErrorKind.networkError =>
          'Fresh nearby information is temporarily unavailable. '
              'Check your internet connection and retry.',
        _ => 'Could not load nearby places right now.',
      };
      notifyListeners();
      return false;
    } catch (_) {
      _loading = false;
      _error = AutopilotErrorKind.invalidData;
      _errorMessage = 'Could not load nearby places right now.';
      notifyListeners();
      return false;
    }
  }

  /// Ranking base point (destination while remote, live position otherwise).
  LatLng? _center;

  void _rank(LatLng center, {String? originLabel}) {
    List<Place> candidates = AutopilotEngine.candidatesFor(
      _dataset,
      _brief,
      excludeLat: center.latitude,
      excludeLng: center.longitude,
    );
    // Provider taxonomies evolve independently (Google may say
    // `historical_landmark`, OSM `tourism=attraction`, Photon just
    // `point_of_interest`). If strict interest matching yields zero, recover
    // with every non-essential real place instead of lying that the whole
    // area is visited/closed. Interest remains a ranking preference whenever
    // a recognised category exists.
    if (candidates.isEmpty && _dataset.isNotEmpty) {
      candidates = AutopilotEngine.candidatesFor(
        _dataset,
        _brief.copyWith(interests: const <AutopilotInterest>{}),
        excludeLat: center.latitude,
        excludeLng: center.longitude,
      );
    }
    // Already-visited/skipped/removed places never come back.
    final Set<String> used = <String>{
      for (final AutopilotStop s in _session?.stops ?? const <AutopilotStop>[])
        if (s.status != AutopilotStopStatus.proposed) s.id,
    };
    final List<Place> fresh = candidates
        .where((Place p) => !used.contains(p.placeId))
        .toList();
    final AutopilotRanking ranking = AutopilotEngine.rankPlaces(
      candidates: fresh,
      brief: _brief,
      here: center,
      now: now(),
      minutesLeft: minutesLeft(),
      realTravelMinutes: _realTravel,
      learnedInterest: _learned,
      originLabel: originLabel,
    );
    _suggestions = ranking.practical;
    _notPractical = ranking.notPractical;
  }

  /// One OSRM table request for the top candidates → real road minutes.
  /// Best-effort: on failure the distance estimates stay (labeled "~").
  ///
  /// SANITY GUARD: a "real" road time that would imply an impossible speed
  /// (the public OSRM server occasionally returns a short hop for a
  /// far destination — that is how "4.9 km away (~1 min ride)" appeared)
  /// is DISCARDED and the labelled estimate is kept instead.
  Future<void> _upgradeWithRealRoutes(LatLng center) async {
    final List<AutopilotSuggestion> top = _suggestions.take(12).toList();
    if (top.isEmpty) return;
    try {
      final String mode = switch (_brief.mode) {
        AutopilotMode.walk => 'walk',
        AutopilotMode.bike => 'bike',
        AutopilotMode.drive => 'car',
      };
      final List<int> minutes = await _osrm.tableMinutes(
        origin: center,
        destinations:
            top.map((AutopilotSuggestion s) => LatLng(s.lat, s.lng)).toList(),
        mode: mode,
      );
      final Map<String, int> real = <String, int>{..._realTravel};
      for (int i = 0; i < top.length && i < minutes.length; i++) {
        final int m = minutes[i];
        if (m <= 0) continue;
        final double distM = top[i].distanceMeters;
        final double impliedKmh = distM * 60 / (1000 * m);
        if (impliedKmh > 110) continue; // physically impossible — drop
        real[top[i].placeId] = m;
        _routeCache[top[i].placeId] = m;
      }
      _realTravel = real;
      if (_realTravel.isNotEmpty) {
        _rank(center, originLabel: _originLabelFor(center));
        notifyListeners();
      }
    } on OsrmException {
      // Estimates remain — the UI keeps showing "~X min" honestly.
    } catch (_) {
      // Never let ranking upgrade break the feature.
    }
  }

  String? _originLabelFor(LatLng center) {
    if (_atDestination) return null;
    final String name = (_brief.endName ?? 'destination').trim();
    return 'from $name';
  }

  // ---------------- Flow: choose / next ----------------

  /// User picked a place ([GO HERE] / [TAKE ME THERE]).
  void choose(AutopilotSuggestion s) {
    final AutopilotSession? session = _session;
    if (session == null) {
      _session = AutopilotSession(
        id: 'ap-${now().millisecondsSinceEpoch}',
        brief: _brief,
        startedAt: now(),
        endsAt: now().add(Duration(minutes: _brief.availableMinutes ?? 120)),
        stops: <AutopilotStop>[],
      );
    }
    // Replace any previously accepted (in-progress) stop.
    final List<AutopilotStop> stops = _session!.stops
        .map((AutopilotStop st) => st.status == AutopilotStopStatus.accepted
            ? st.copyWith(status: AutopilotStopStatus.visited)
            : st)
        .toList();
    _session = AutopilotSession(
      id: _session!.id,
      brief: _session!.brief,
      startedAt: _session!.startedAt,
      endsAt: _session!.endsAt,
      stops: [...stops, s.toStop(AutopilotStopStatus.accepted)],
      originName: _session!.originName,
      originLat: _session!.originLat ?? _lastHere?.latitude,
      originLng: _session!.originLng ?? _lastHere?.longitude,
    );
    _learn(s.category);
    _plan = null;
    _recovery = null;
    _save();
    _watchArrival();
    notifyListeners();
  }

  void _learn(String category) {
    if (category.isEmpty) return;
    _learned[category] = math.min(9, (_learned[category] ?? 0) + 1);
  }

  /// Arrived at the current stop (real geofence ≤ 80 m, or simulated).
  void markArrived() {
    final AutopilotStop? cur = currentStop;
    if (cur == null) return;
    _replaceStop(cur.id, cur.copyWith(
      status: AutopilotStopStatus.visited,
      arrivedAt: now(),
    ));
    unawaited(_arrivalSub?.cancel());
    _arrivalSub = null;
    _liveTicker?.cancel();
    _liveTicker = null;
    _liveReset();
    _save();
    notifyListeners();
  }

  /// "What next?" — recompute from the current location for the time left.
  Future<bool> whatNext() => recompute();

  /// [SKIP] a suggestion → never recommended again this session.
  Future<void> skip(AutopilotSuggestion s) async {
    final AutopilotSession? session = _session;
    if (session == null) return;
    _session = AutopilotSession(
      id: session.id,
      brief: session.brief,
      startedAt: session.startedAt,
      endsAt: session.endsAt,
      stops: [...session.stops, s.toStop(AutopilotStopStatus.skipped)],
      originName: session.originName,
      originLat: session.originLat,
      originLng: session.originLng,
    );
    await _save();
    await recompute();
  }

  /// [REMOVE] a stop from the plan.
  Future<void> removeStop(String stopId) async {
    final AutopilotSession? session = _session;
    if (session == null) return;
    _session = AutopilotSession(
      id: session.id,
      brief: session.brief,
      startedAt: session.startedAt,
      endsAt: session.endsAt,
      stops: session.stops
          .map((AutopilotStop st) =>
              st.id == stopId ? st.copyWith(status: AutopilotStopStatus.removed) : st)
          .toList(),
      originName: session.originName,
      originLat: session.originLat,
      originLng: session.originLng,
    );
    await _save();
    notifyListeners();
  }

  /// 🔄 CHANGE PLAN: new interests → future recommendations only.
  Future<bool> changeInterests(Set<AutopilotInterest> interests) async {
    _brief = _brief.copyWith(interests: interests);
    final AutopilotSession? session = _session;
    if (session != null) {
      _session = AutopilotSession(
        id: session.id,
        brief: _brief,
        startedAt: session.startedAt,
        endsAt: session.endsAt,
        stops: session.stops,
        originName: session.originName,
        originLat: session.originLat,
        originLng: session.originLng,
      );
      await _save();
    }
    return recompute();
  }

  /// Session-only interest learning reset.
  Future<void> resetPreferences() async {
    _learned.clear();
    await _save();
    notifyListeners();
  }

  // ---------------- ⚡ AUTO PLAN ----------------

  AutopilotPlan generatePlan() {
    final int returnMin = _returnTravelMinutes();
    final AutopilotPlan p = AutopilotEngine.buildAutoPlan(
      ranked: _suggestions,
      minutesLeft: minutesLeft(),
      returnMinutes: returnMin > 0 ? returnMin : null,
    );
    _plan = p;
    notifyListeners();
    return p;
  }

  int _returnTravelMinutes() {
    final AutopilotBrief b = _brief;
    final LatLng? here = _lastHere;
    if (b.endLat == null || b.endLng == null || here == null) return 0;
    // While travelling TO the destination the time budget is for the day at
    // the place — the journey itself must not eat the plan's stops.
    if (!_atDestination) return 0;
    return AutopilotEngine.estimateTravelMinutes(
      GeoUtils.distanceMeters(here, LatLng(b.endLat!, b.endLng!)),
      b.mode,
    );
  }

  /// [START THIS PLAN]: queue all plan stops (first becomes accepted).
  Future<void> startPlan() async {
    final AutopilotPlan? p = _plan;
    if (p == null || p.steps.isEmpty) return;
    final AutopilotSession? session = _session;
    if (session == null) {
      _session = AutopilotSession(
        id: 'ap-${now().millisecondsSinceEpoch}',
        brief: _brief,
        startedAt: now(),
        endsAt: now().add(Duration(minutes: _brief.availableMinutes ?? 120)),
        stops: const <AutopilotStop>[],
      );
    }
    final List<AutopilotStop> stops = <AutopilotStop>[];
    for (int i = 0; i < p.steps.length; i++) {
      final AutopilotPlanStep step = p.steps[i];
      stops.add(step.suggestion.toStop(i == 0
          ? AutopilotStopStatus.accepted
          : AutopilotStopStatus.proposed));
    }
    _session = AutopilotSession(
      id: _session!.id,
      brief: _session!.brief,
      startedAt: _session!.startedAt,
      endsAt: _session!.endsAt,
      stops: [..._session!.stops, ...stops],
      originName: _session!.originName,
      originLat: _session!.originLat ?? _lastHere?.latitude,
      originLng: _session!.originLng ?? _lastHere?.longitude,
    );
    _learn(p.steps.first.suggestion.category);
    _plan = null;
    await _save();
    _watchArrival();
    notifyListeners();
  }

  /// What to ask the place providers for when a traveller picked an interest.
  /// The enum names ("eat", "relax") are UI words, not searchable place
  /// types — searching them verbatim returns nothing useful.
  static const Map<AutopilotInterest, String> _interestSearchTerm =
      <AutopilotInterest, String>{
    AutopilotInterest.eat: 'restaurant',
    AutopilotInterest.explore: 'tourist attraction',
    AutopilotInterest.shopping: 'shopping mall',
    AutopilotInterest.relax: 'park',
    AutopilotInterest.entertainment: 'cinema',
    AutopilotInterest.sightseeing: 'viewpoint',
    AutopilotInterest.historical: 'monument',
    AutopilotInterest.family: 'amusement park',
    AutopilotInterest.work: 'cafe',
    AutopilotInterest.roadtrip: 'tourist attraction',
    AutopilotInterest.other: 'tourist attraction',
  };

  /// Interest-by-interest radius search, used when the cached nearby dataset
  /// came back empty (fresh city, cache off, or every tile provider timing
  /// out together). Sequential on purpose: Nominatim and Overpass rate-limit
  /// hard, and six parallel searches would simply get refused. Duplicates are
  /// dropped by name + position so a place found under two interests counts
  /// once.
  Future<List<Place>> _wideSweep(LatLng center) async {
    final List<String> wanted = <String>{
      ..._brief.interests
          .map((AutopilotInterest i) => _interestSearchTerm[i] ?? 'attraction'),
      'tourist attraction',
      'historical landmark',
      'place of worship',
      'museum',
      'park',
      'restaurant',
      'shopping mall',
    }.toList();
    final List<Place> out = <Place>[];
    final Set<String> seen = <String>{};
    for (final String label in wanted.take(8)) {
      // A useful 10-hour plan needs more than two cards. Stop at 18 unique
      // places, while still keeping provider calls sequential/rate-safe.
      if (out.length >= 18) break;
      try {
        final List<Place> found = await _places
            .search(label, location: center, radiusMeters: 25000)
            .timeout(const Duration(seconds: 10));
        for (final Place p in found) {
          if (p.category == 'locality' ||
              p.category == 'administrative' ||
              p.category == 'country') {
            continue;
          }
          final String k = '${p.name.toLowerCase()}'
              '@${p.lat.toStringAsFixed(3)},${p.lng.toStringAsFixed(3)}';
          if (!seen.add(k)) continue;
          out.add(p);
        }
      } catch (_) {
        // One interest failing must not sink the whole sweep.
      }
    }
    return out;
  }

  // ---------------- 🛟 FIX MY TRIP (recovery) ----------------

  void fixMyTrip() {
    final AutopilotSession? session = _session;
    if (session == null) return;
    final List<AutopilotStop> pending = session.stops
        .where((AutopilotStop st) => st.status == AutopilotStopStatus.proposed)
        .toList();
    final AutopilotRecovery r = AutopilotEngine.recoverPlan(
      pending: pending,
      minutesLeft: minutesLeft(),
    );
    _recovery = r;
    notifyListeners();
  }

  /// [APPLY] the recovery: pending stops = kept ones only.
  Future<void> applyRecovery() async {
    final AutopilotSession? session = _session;
    final AutopilotRecovery? r = _recovery;
    if (session == null || r == null) return;
    final Set<String> keepIds = <String>{for (final AutopilotStop s in r.keep) s.id};
    _session = AutopilotSession(
      id: session.id,
      brief: session.brief,
      startedAt: session.startedAt,
      endsAt: session.endsAt,
      stops: session.stops
          .map((AutopilotStop st) =>
              (st.status == AutopilotStopStatus.proposed && !keepIds.contains(st.id))
                  ? st.copyWith(status: AutopilotStopStatus.skipped,
                      reason: 'Removed to fit your remaining time')
                  : st)
          .toList(),
      originName: session.originName,
      originLat: session.originLat,
      originLng: session.originLng,
    );
    _recovery = null;
    await _save();
    notifyListeners();
  }

  void discardRecovery() {
    _recovery = null;
    notifyListeners();
  }

  // ---------------- 😴 BREAK ----------------

  /// Nearby cafe/park options for a break, straight from the cached dataset.
  List<AutopilotSuggestion> breakOptions() {
    final LatLng? here = _center ?? _lastHere;
    if (here == null) return const <AutopilotSuggestion>[];
    final List<Place> calm = _dataset
        .where((Place p) =>
            p.category == 'cafe' || p.category == 'park' ||
            p.category == 'restaurant')
        .toList();
      final AutopilotRanking r = AutopilotEngine.rankPlaces(
      candidates: AutopilotEngine.candidatesFor(calm, const AutopilotBrief(),
          excludeLat: here.latitude, excludeLng: here.longitude),
      brief: const AutopilotBrief(maxTravelMinutes: 20),
      here: here,
      now: now(),
      minutesLeft: minutesLeft(),
      realTravelMinutes: _realTravel,
      originLabel: _originLabelFor(here),
    );
    return r.practical.take(5).toList();
  }

  /// Records a 30-minute break (time accounting stays honest).
  Future<void> takeBreak() async {
    final AutopilotSession? session = _session;
    if (session == null) return;
    _session = AutopilotSession(
      id: session.id,
      brief: session.brief,
      startedAt: session.startedAt,
      endsAt: session.endsAt,
      stops: [...session.stops, AutopilotStop(
        id: 'break-${now().millisecondsSinceEpoch}',
        name: 'Break',
        lat: 0, lng: 0,
        category: 'break',
        status: AutopilotStopStatus.visited,
        visitMinutes: 30,
      )],
      originName: session.originName,
      originLat: session.originLat,
      originLng: session.originLng,
    );
    await _save();
    notifyListeners();
  }

  // ---------------- Stop / end ----------------

  Future<void> stopAutopilot() async {
    await _arrivalSub?.cancel();
    _arrivalSub = null;
    _liveTicker?.cancel();
    _liveTicker = null;
    _liveReset();
    _session = null;
    _brief = const AutopilotBrief();
    _suggestions = const <AutopilotSuggestion>[];
    _notPractical = const <(AutopilotSuggestion, String)>[];
    _plan = null;
    _recovery = null;
    _dataset = const <Place>[];
    _datasetKey = null;
    _realTravel = const <String, int>{};
    _center = null;
    _atDestination = false;
    _destinationDistanceMeters = 0;
    await _save();
    notifyListeners();
  }

  // ---------------- Arrival geofence + live tracking ----------------

  /// Straight-line distance from the traveller to the stop the plan expects
  /// them at right now (null until a GPS fix has been seen this hop).
  double? get liveDistanceMeters => _liveDistanceMeters;

  /// When the last fix landed, so the UI can admit a stale GPS signal.
  DateTime? get liveFixAt => _liveFixAt;

  /// The distance to the stop grew by more than 60 m on the last fix — the
  /// traveller is heading away from it (wrong turn, detour, or done early).
  bool get liveMovingAway => _liveMovingAway;

  /// Minutes behind the plan for the current hop. The schedule is the plan
  /// itself: session start + everything planned up to and including this
  /// stop's travel. Zero while on time, so the UI can stay quiet.
  int get liveLagMinutes {
    final AutopilotSession? s = _session;
    final AutopilotStop? cur = s?.currentStop;
    if (s == null || cur == null) return 0;
    Duration due = Duration.zero;
    for (final AutopilotStop st in s.stops) {
      due += Duration(minutes: (st.travelMinutes ?? 0) + st.visitMinutes);
      if (st.id == cur.id) {
        due -= Duration(minutes: st.visitMinutes);
        break;
      }
    }
    final int late = now().difference(s.startedAt.add(due)).inMinutes;
    return late < 0 ? 0 : late;
  }

  /// Travel minutes still planned for the current hop (0 once its window has
  /// passed — the lag counter takes over from there).
  int get liveEtaMinutes {
    final AutopilotStop? cur = currentStop;
    if (cur == null || liveLagMinutes > 0) return 0;
    return cur.travelMinutes ?? 0;
  }

  /// Where the traveller should be by now, for the status card's "you are
  /// here / you should be here" line. Null when nothing is in progress.
  AutopilotStop? get liveExpectedStop => _session?.currentStop;

  void _liveReset() {
    _liveDistanceMeters = null;
    _livePrevDistanceMeters = null;
    _liveFixAt = null;
    _liveMovingAway = false;
  }

  /// Geofences arrival at the current stop AND keeps the live readout fresh.
  /// Called whenever the in-progress stop changes (choose, plan, restore).
  void _watchArrival() {
    unawaited(_arrivalSub?.cancel());
    _arrivalSub = null;
    _liveTicker?.cancel();
    _liveTicker = null;
    _liveReset();
    final AutopilotStop? first = currentStop;
    if (first == null) return;
    if (_debugPosition != null) {
      // Simulated position (developer mode) — no GPS stream to follow, but
      // the readout must still say what the plan expects.
      _liveDistanceMeters = GeoUtils.distanceMetersLL(_debugPosition!.latitude,
          _debugPosition!.longitude, first.lat, first.lng);
      _liveFixAt = now();
      return;
    }
    _arrivalSub = _location
        // 30 m: arrival at a stop is detected within a building's width,
        // while a stationary phone stops burning fixes every few metres.
        .watchPosition(distanceFilter: 30)
        .listen((Position p) {
      final AutopilotStop? cur = currentStop;
      if (cur == null) return;
      final double d = GeoUtils.distanceMetersLL(
          p.latitude, p.longitude, cur.lat, cur.lng);
      _livePrevDistanceMeters = _liveDistanceMeters;
      _liveDistanceMeters = d;
      _liveFixAt = now();
      final double? prev = _livePrevDistanceMeters;
      _liveMovingAway = prev != null && prev > 250 && d > prev + 60;
      if (d <= 80) {
        markArrived();
        return;
      }
      notifyListeners();
    }, onError: (Object _) {});
    // Aging, not polling: with the phone in a pocket and no movement past the
    // distance filter there are no new fixes, yet "5 min left" must not sit
    // on screen claiming freshness for an hour.
    // 30 s is often enough to age the readout; 20 s woke the UI (and the
    // radio) 50% more often for no extra information.
    _liveTicker = Timer.periodic(const Duration(seconds: 30), (Timer _) {
      if (currentStop == null) return;
      notifyListeners();
    });
  }

  // ---------------- Debug / developer simulation ----------------
  // Hidden from normal production UI (see AutopilotScreen gating).

  void setDebugTimeOffset(Duration offset) {
    _debugTimeOffset = offset;
    notifyListeners();
  }

  void setDebugPosition(LatLng? p) {
    _debugPosition = p;
    notifyListeners();
  }

  void debugSimulateArrival() => markArrived();

  void debugSimulateDelay(int minutes) {
    _debugTimeOffset += Duration(minutes: minutes);
    notifyListeners();
  }

  void debugSimulateSkip() {
    final AutopilotStop? cur = currentStop;
    if (cur != null) {
      _replaceStop(cur.id, cur.copyWith(
          status: AutopilotStopStatus.skipped, reason: 'Simulated skip'));
    } else if (_suggestions.isNotEmpty) {
      unawaited(skip(_suggestions.first));
      return;
    }
    notifyListeners();
  }

  // ---------------- Helpers ----------------

  void _replaceStop(String id, AutopilotStop updated) {
    final AutopilotSession? session = _session;
    if (session == null) return;
    _session = AutopilotSession(
      id: session.id,
      brief: session.brief,
      startedAt: session.startedAt,
      endsAt: session.endsAt,
      stops: session.stops
          .map((AutopilotStop st) => st.id == id ? updated : st)
          .toList(),
      originName: session.originName,
      originLat: session.originLat,
      originLng: session.originLng,
    );
  }

  @override
  void dispose() {
    unawaited(_updatesSub?.cancel());
    unawaited(_arrivalSub?.cancel());
    _liveTicker?.cancel();
    super.dispose();
  }
}
