// Deterministic PRICE COMPARISON for the Tourism booking hub.
//
// WHY THIS EXISTS: a traveller wants "sab platforms ka price ek hi click me".
// Live fares need partner APIs this app does not have, so this module does the
// honest thing instead of inventing numbers:
//
//   * every quote is a clearly labelled ESTIMATE built from a published-style
//     rate card (base + per-km, or per-km by class) that is the SAME for every
//     platform — only the platform's own multiplier and fee differ;
//   * the basis string is shown next to every number ("8.4 km × ₹14/km + ₹50"),
//     so the traveller can see exactly where it came from;
//   * each row carries a CONFIDENCE (high when we know the real road distance,
//     low for hotels where "price" depends on the property) and every screen
//     that shows these must say "estimate — tap to check the live fare";
//   * the row's button opens the platform's VERIFIED official flow with the
//     query prefilled, which is where the real, bookable price lives.
//
// Nothing here claims to be a live fare, and nothing here is random: the same
// inputs always produce the same output (see test/price_compare_test.dart).

import 'booking_models.dart';

/// How much the estimate can be trusted. Surfaced in the UI so a driver's
/// actual quote is never confused with a modelled one.
enum PriceConfidence { high, medium, low, unknown }

extension PriceConfidenceInfo on PriceConfidence {
  String get label => switch (this) {
        // "Good estimate" sounded like fare accuracy. What is high here is
        // the INPUT quality (a real road route), not a promise that provider
        // surge/discounts are known.
        PriceConfidence.high => 'Route-based range',
        PriceConfidence.medium => 'Indicative range',
        PriceConfidence.low => 'Wide estimate',
        PriceConfidence.unknown => 'No estimate — check live',
      };

  /// Dot colour metaphor used by the UI (actual colours live in the widget).
  int get rank => switch (this) {
        PriceConfidence.high => 3,
        PriceConfidence.medium => 2,
        PriceConfidence.low => 1,
        PriceConfidence.unknown => 0,
      };
}

/// One platform's modelled price for one query.
class PlatformQuote {
  const PlatformQuote({
    required this.providerId,
    required this.providerName,
    required this.emoji,
    required this.confidence,
    required this.basis,
    this.low,
    this.high,
    this.link,
    this.note = '',
  });

  final String providerId;
  final String providerName;
  final String emoji;
  final PriceConfidence confidence;

  /// Estimated total for the whole query (already × passengers/rooms).
  final int? low;
  final int? high;

  /// The arithmetic behind the number, shown verbatim in the UI.
  final String basis;

  /// VERIFIED official deep/universal link with the query prefilled.
  final String? link;
  final String note;

  bool get hasPrice => low != null && high != null;

  /// Mid-point, used only for ordering and for "cheapest" labelling.
  int get mid => hasPrice ? ((low! + high!) / 2).round() : 0;
}

/// A full trip budget — the "travel agent" view: what the WHOLE trip costs,
/// not just one leg.
class TripEstimate {
  const TripEstimate({
    required this.travelLow,
    required this.travelHigh,
    required this.stayLow,
    required this.stayHigh,
    required this.foodLow,
    required this.foodHigh,
    required this.localLow,
    required this.localHigh,
    required this.activitiesLow,
    required this.activitiesHigh,
    required this.days,
    required this.pax,
    required this.basis,
  });

  final int travelLow;
  final int travelHigh;
  final int stayLow;
  final int stayHigh;
  final int foodLow;
  final int foodHigh;
  final int localLow;
  final int localHigh;
  final int activitiesLow;
  final int activitiesHigh;
  final int days;
  final int pax;
  final String basis;

  int get totalLow => travelLow + stayLow + foodLow + localLow + activitiesLow;
  int get totalHigh =>
      travelHigh + stayHigh + foodHigh + localHigh + activitiesHigh;

  /// Cheapest realistic daily spend — what a budget traveller should carry.
  int get perDayLow => days <= 0 ? totalLow : (totalLow / days).round();
  int get perDayHigh => days <= 0 ? totalHigh : (totalHigh / days).round();
}

/// Transparent rate card. These are ORDER-OF-MAGNITUDE Indian rates used only
/// to compare platforms against each other — they are the same for every
/// platform except the documented multiplier.
class PriceCompare {
  PriceCompare._();

  // ---- Rides (base ₹ + ₹/km + ₹/min, minimum fare) -----------------------
  // These are APP-RIDE effective rates, not a city's meter tariff. The old
  // ₹25 + ₹12/km auto card produced ₹50–64 for the user's real 2.1 km ride —
  // far below what providers show once pickup, time, platform fee and demand
  // are included. Conservative minimums + wider upper bands are deliberate:
  // under-budgeting a traveller is worse than showing an honest wide range.
  static const Map<String, _RideRate> _rideRates = <String, _RideRate>{
    'bike': _RideRate(base: 25, perKm: 6, perMin: 0.8, min: 40),
    'auto': _RideRate(base: 45, perKm: 15, perMin: 1.5, min: 80),
    'cab': _RideRate(base: 85, perKm: 19, perMin: 2.0, min: 130),
    'sedan': _RideRate(base: 105, perKm: 22, perMin: 2.4, min: 160),
    'suv': _RideRate(base: 140, perKm: 27, perMin: 2.8, min: 220),
  };

  /// Platform character: what each one typically costs relative to the card,
  /// and the convenience/booking fee it adds. Documented so the number is
  /// never a mystery.
  static const Map<String, _PlatformFactor> _rideFactors =
      <String, _PlatformFactor>{
    'uber': _PlatformFactor(1.05, 12, 'Route-card estimate; Uber\'s actual '
        'upfront fare may add demand, tolls or discounts.'),
    'ola': _PlatformFactor(1.00, 10, 'Route-card estimate; Ola Prime/Plus, '
        'demand and coupons can change the live fare.'),
    'rapido': _PlatformFactor(0.98, 8, 'Route-card estimate; Rapido exposes '
        'no public live-fare or location-prefill API.'),
  };

  // ---- Inter-city (₹/km by class/service, minimum fare) ------------------
  static const Map<String, double> _trainPerKm = <String, double>{
    '2S': 0.45,
    'SL': 0.55,
    'CC': 1.20,
    '3A': 1.45,
    '2A': 2.05,
    '1A': 3.10,
  };
  static const double _trainFixed = 20; // reservation + superfast-ish charge

  static const Map<String, double> _busPerKm = <String, double>{
    'ordinary': 1.10,
    'ac': 1.75,
    'sleeper': 2.20,
  };

  /// Airfare: base + per-km, multiplied by how close to departure you book.
  static const double _flightBase = 1500;
  static const double _flightPerKm = 4.20;

  /// Hotel tiers (per room per night, before platform discounts).
  static const Map<String, _Band> _hotelTiers = <String, _Band>{
    'budget': _Band(1200, 2500),
    'standard': _Band(2600, 5500),
    'premium': _Band(6000, 14000),
  };

  /// Platform behaviour for stays/flights/trains/buses.
  static const Map<String, _PlatformFactor> _otaFactors =
      <String, _PlatformFactor>{
    'makemytrip-flights': _PlatformFactor(1.00, 0, 'MakeMyTrip: baseline OTA pricing '
        'plus bank/card offers at checkout.'),
    'goibibo-flights': _PlatformFactor(0.98, 0, 'Goibibo: usually a hair below MMT '
        'and heavy on GoCash discounts.'),
    'booking-com': _PlatformFactor(1.05, 0, 'Booking.com: slightly higher rack '
        'rates, free cancellation more often.'),
    'oyo': _PlatformFactor(0.80, 0, 'Oyo: cheapest inventory, quality varies '
        'a lot by property.'),
    'irctc': _PlatformFactor(1.00, 15, 'IRCTC: the official fare + booking '
        'fee; no surge, no markup.'),
    'redbus': _PlatformFactor(1.00, 25, 'redBus: operator fare + small '
        'convenience fee.'),
    'zoomcar': _PlatformFactor(1.00, 0, 'Zoomcar: daily rate + security '
        'deposit + fuel.'),
    'headout': _PlatformFactor(1.05, 0, 'Headout: curated experiences, '
        'instant confirmation.'),
    'klook': _PlatformFactor(1.00, 0, 'Klook: often the cheapest for '
        'attraction tickets.'),
  };

  /// Daily living costs while travelling (per person).
  static const _Band _foodPerDay = _Band(400, 900);
  static const _Band _localPerDay = _Band(200, 600);
  static const _Band _activitiesPerDay = _Band(300, 1200);

  // =======================================================================
  // RIDES
  // =======================================================================

  /// Quotes for every ride platform. [distanceKm] and [minutes] should come
  /// from the real route when there is one (high confidence); without a
  /// distance the rows are returned with no numbers rather than a guess.
  static List<PlatformQuote> forRide({
    required List<BookingProvider> providers,
    required BookingQuery query,
    double? distanceKm,
    double? minutes,
    String vehicle = 'cab',
    Map<String, double> learnedFactors = const <String, double>{},
    DateTime? pricedAt,
  }) {
    final _RideRate rate = _rideRates[vehicle] ?? _rideRates['cab']!;
    final DateTime clock = pricedAt ?? DateTime.now();
    // Not "live surge": just an honest wider planning factor for the hours
    // where app rides commonly cost more. The UI explicitly calls it that.
    final double demand = switch (clock.hour) {
      >= 7 && <= 10 => 1.18,
      >= 17 && <= 21 => 1.18,
      >= 22 || <= 5 => 1.25,
      _ => 1.05,
    };
    final List<PlatformQuote> out = <PlatformQuote>[];
    for (final BookingProvider p in providers) {
      final _PlatformFactor f =
          _rideFactors[p.providerId] ?? const _PlatformFactor(1.0, 0, '');
      final String? link = _officialLink(p, query);
      if (distanceKm == null || distanceKm <= 0) {
        out.add(PlatformQuote(
          providerId: p.providerId,
          providerName: p.providerName,
          emoji: p.emoji,
          confidence: PriceConfidence.unknown,
          basis: 'Distance unknown — open the app for the live fare.',
          link: link,
          note: f.note,
        ));
        continue;
      }
      final double mins = minutes ?? (distanceKm / 22 * 60); // ~22 km/h city
      final double learned =
          (learnedFactors[p.providerId] ?? 1.0).clamp(0.65, 2.50);
      final double raw = (rate.base +
              distanceKm * rate.perKm +
              mins * rate.perMin +
              f.fee) *
          f.factor *
          demand *
          learned;
      final int mid = raw < rate.min ? rate.min : raw.round();
      out.add(PlatformQuote(
        providerId: p.providerId,
        providerName: p.providerName,
        emoji: p.emoji,
        confidence: PriceConfidence.high,
        // Wide by design: provider demand, pickup distance, tolls and offers
        // are not available without its partner API.
        low: (mid * 0.85).round(),
        high: (mid * 1.45).round(),
        basis: '${distanceKm.toStringAsFixed(1)} km × ₹${_money(rate.perKm)}/km '
            '+ ₹${_money(rate.base)} pickup/base + ~${mins.round()} min'
            '${f.fee > 0 ? ' + ₹${_money(f.fee)} platform fee' : ''}'
            ' × ${demand.toStringAsFixed(2)} time buffer'
            '${f.factor != 1 ? ' × ${f.factor} provider' : ''}'
            '${learned != 1 ? ' × ${learned.toStringAsFixed(2)} learned' : ''}',
        link: link,
        note: f.note,
      ));
    }
    return _sorted(out);
  }

  // =======================================================================
  // TRAINS / BUSES / FLIGHTS / HOTELS / ACTIVITIES
  // =======================================================================

  /// Quotes for an inter-city category. [distanceKm] is the GREAT-CIRCLE
  /// distance between the two city names — real rail/road/air distances differ,
  /// which is exactly why confidence is `medium` here, never `high`.
  static List<PlatformQuote> forTravel({
    required BookingCategory category,
    required List<BookingProvider> providers,
    required BookingQuery query,
    required int pax,
    required DateTime date,
    double? distanceKm,
    int nights = 1,
    String? trainClass,
    String? busClass,
    String? hotelTier,
  }) {
    final List<PlatformQuote> out = <PlatformQuote>[];
    final String? link0 =
        providers.isEmpty ? null : _officialLink(providers.first, query);
    if (distanceKm == null || distanceKm <= 0) {
      return <PlatformQuote>[
        for (final BookingProvider p in providers)
          PlatformQuote(
            providerId: p.providerId,
            providerName: p.providerName,
            emoji: p.emoji,
            confidence: PriceConfidence.unknown,
            basis: 'Distance unknown — open the provider to see fares.',
            link: _officialLink(p, query) ?? link0,
            note: _otaFactors[p.providerId]?.note ?? '',
          ),
      ];
    }

    for (final BookingProvider p in providers) {
      final _PlatformFactor f =
          _otaFactors[p.providerId] ?? const _PlatformFactor(1.0, 0, '');
      final String? link = _officialLink(p, query);
      final String basisPrefix =
          '${distanceKm.toStringAsFixed(0)} km straight-line';
      switch (category) {
        case BookingCategory.train:
          final double perKm = _trainPerKm[(trainClass ?? 'SL').toUpperCase()] ??
              _trainPerKm['SL']!;
          final int perHead =
              (distanceKm * perKm + _trainFixed + f.fee).round();
          out.add(_mk(
            p: p,
            f: f,
            link: link,
            low: perHead * pax,
            high: (perHead * 1.25).round() * pax,
            confidence: PriceConfidence.medium,
            basis: '$basisPrefix × ₹${_money(perKm)}/km ${trainClass ?? 'SL'} '
                '+ ₹${_money(_trainFixed)} charges, × $pax traveller(s)',
          ));
        case BookingCategory.bus:
          final double perKm = _busPerKm[busClass ?? 'ac'] ?? _busPerKm['ac']!;
          final int perHead = (distanceKm * perKm + f.fee).round();
          out.add(_mk(
            p: p,
            f: f,
            link: link,
            low: perHead * pax,
            high: (perHead * 1.35).round() * pax,
            confidence: PriceConfidence.medium,
            basis: '$basisPrefix × ₹${_money(perKm)}/km ${busClass ?? 'ac'}, '
                '× $pax traveller(s)',
          ));
        case BookingCategory.flight:
          final double advance = _flightAdvanceFactor(date);
          final int perHead =
              ((_flightBase + distanceKm * _flightPerKm) * advance * f.factor)
                  .round();
          out.add(_mk(
            p: p,
            f: f,
            link: link,
            low: (perHead * 0.85).round() * pax,
            high: (perHead * 1.45).round() * pax,
            confidence: PriceConfidence.low,
            basis: '₹${_flightBase.round()} + $basisPrefix × '
                '₹$_flightPerKm/km, × ${advance.toStringAsFixed(2)} '
                'for booking ${_daysAhead(date)} days ahead, '
                '× $pax traveller(s)',
          ));
        case BookingCategory.hotel:
          final _Band tier = _hotelTiers[hotelTier ?? 'standard'] ??
              _hotelTiers['standard']!;
          final int low = (tier.low * f.factor).round() * nights;
          final int high = (tier.high * f.factor).round() * nights;
          out.add(_mk(
            p: p,
            f: f,
            link: link,
            low: low,
            high: high,
            confidence: PriceConfidence.low,
            basis: '₹${tier.low}–₹${tier.high}/night '
                '${hotelTier ?? 'standard'} × $nights night(s)'
                '${f.factor != 1 ? ' × ${f.factor}' : ''}',
          ));
        case BookingCategory.carRental:
          // Daily rental: km allowance is per day, so charge the road km.
          final int days = nights < 1 ? 1 : nights;
          final int low = (1400 * days * f.factor).round();
          final int high = (2600 * days * f.factor).round();
          out.add(_mk(
            p: p,
            f: f,
            link: link,
            low: low,
            high: high,
            confidence: PriceConfidence.medium,
            basis: '₹1,400–₹2,600/day × $days day(s) (fuel extra — '
                '$basisPrefix of driving)',
          ));
        case BookingCategory.activities:
          final int low = (600 * f.factor).round() * pax;
          final int high = (2500 * f.factor).round() * pax;
          out.add(_mk(
            p: p,
            f: f,
            link: link,
            low: low,
            high: high,
            confidence: PriceConfidence.low,
            basis: '₹600–₹2,500 per experience × $pax traveller(s)',
          ));
        case BookingCategory.ride:
          // Handled by forRide; keep the compiler exhaustive.
          out.add(_mk(
            p: p,
            f: f,
            link: link,
            low: null,
            high: null,
            confidence: PriceConfidence.unknown,
            basis: 'Use the ride comparison.',
          ));
      }
    }
    return _sorted(out);
  }

  // =======================================================================
  // TRIP BUDGET (the "travel agent" view)
  // =======================================================================

  /// What the WHOLE trip costs, per group: travel + stay + food + local
  /// transport + activities. Deterministic, and every line says where it came
  /// from. [distanceKm] is one-way; travel is charged both ways unless the
  /// query is one-way ([roundTrip] false).
  static TripEstimate trip({
    required BookingCategory category,
    required int days,
    required int pax,
    required double distanceKm,
    bool roundTrip = true,
    String hotelTier = 'standard',
    String? trainClass,
    String? busClass,
  }) {
    final int nights = days < 1 ? 1 : days;
    final double chargeKm = distanceKm * (roundTrip ? 2 : 1);
    int tLow;
    int tHigh;
    String travelBasis;
    switch (category) {
      case BookingCategory.train:
        final double perKm =
            _trainPerKm[(trainClass ?? 'SL').toUpperCase()] ?? _trainPerKm['SL']!;
        tLow = ((chargeKm * perKm + _trainFixed) * pax).round();
        tHigh = (tLow * 1.25).round();
        travelBasis = 'Train ${trainClass ?? 'SL'} × $pax × '
            '${chargeKm.toStringAsFixed(0)} km';
      case BookingCategory.bus:
        final double perKm = _busPerKm[busClass ?? 'ac'] ?? _busPerKm['ac']!;
        tLow = ((chargeKm * perKm) * pax).round();
        tHigh = (tLow * 1.35).round();
        travelBasis = 'Bus ${busClass ?? 'ac'} × $pax × '
            '${chargeKm.toStringAsFixed(0)} km';
      case BookingCategory.flight:
        tLow = ((_flightBase + chargeKm * _flightPerKm) * 0.85 * pax).round();
        tHigh = ((_flightBase + chargeKm * _flightPerKm) * 1.45 * pax).round();
        travelBasis = 'Flights × $pax return';
      case BookingCategory.ride:
      case BookingCategory.carRental:
        tLow = (1400 * nights * 1.0).round();
        tHigh = (2600 * nights * 1.0).round();
        travelBasis = 'Self-drive/cab ₹1,400–₹2,600 × $nights day(s)';
      case BookingCategory.hotel:
      case BookingCategory.activities:
        tLow = ((chargeKm * 14) * pax).round();
        tHigh = ((chargeKm * 18) * pax).round();
        travelBasis = 'Local travel ₹14–18/km × ${chargeKm.toStringAsFixed(0)} km';
    }

    final _Band tier = _hotelTiers[hotelTier] ?? _hotelTiers['standard']!;
    final int rooms = (pax / 2).ceil() < 1 ? 1 : (pax / 2).ceil();
    final int stayLow = tier.low * rooms * nights;
    final int stayHigh = tier.high * rooms * nights;
    final int foodLow = _foodPerDay.low * pax * days;
    final int foodHigh = _foodPerDay.high * pax * days;
    final int localLow = _localPerDay.low * pax * days;
    final int localHigh = _localPerDay.high * pax * days;
    final int actLow = _activitiesPerDay.low * pax * days;
    final int actHigh = _activitiesPerDay.high * pax * days;

    return TripEstimate(
      travelLow: tLow,
      travelHigh: tHigh,
      stayLow: stayLow,
      stayHigh: stayHigh,
      foodLow: foodLow,
      foodHigh: foodHigh,
      localLow: localLow,
      localHigh: localHigh,
      activitiesLow: actLow,
      activitiesHigh: actHigh,
      days: days,
      pax: pax,
      basis: '$travelBasis · $hotelTier stay × $rooms room(s) '
          '× $nights night(s) · food ₹${_foodPerDay.low}–${_foodPerDay.high}'
          '/person/day · local ₹${_localPerDay.low}–${_localPerDay.high}'
          '/person/day',
    );
  }

  // ---------------- internals ----------------

  static PlatformQuote _mk({
    required BookingProvider p,
    required _PlatformFactor f,
    required String? link,
    required int? low,
    required int? high,
    required PriceConfidence confidence,
    required String basis,
  }) =>
      PlatformQuote(
        providerId: p.providerId,
        providerName: p.providerName,
        emoji: p.emoji,
        confidence: confidence,
        low: low,
        high: high,
        basis: basis,
        link: link,
        note: f.note,
      );

  /// Best official URL the comparison can expose. App-only providers such
  /// as Rapido have no public web fare link, so their verified Play Store
  /// listing is the honest final fallback (the BookingService still tries
  /// the installed Android package first when the row is tapped).
  static String? _officialLink(BookingProvider p, BookingQuery q) =>
      p.webLinkBuilder?.call(q) ?? p.plainWebUrl ?? p.playStoreUrl;

  /// Prints a whole number without a pointless ".0" so the arithmetic in the
  /// UI reads the way a human would write it ("₹14/km", not "₹14.0/km").
  static String _money(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);

  /// Cheapest first; platforms we cannot price stay at the bottom but never
  /// disappear — the traveller still needs the way to open them.
  static List<PlatformQuote> _sorted(List<PlatformQuote> inList) {
    final List<PlatformQuote> out = List<PlatformQuote>.of(inList);
    out.sort((PlatformQuote a, PlatformQuote b) {
      if (a.hasPrice && !b.hasPrice) return -1;
      if (!a.hasPrice && b.hasPrice) return 1;
      if (!a.hasPrice && !b.hasPrice) {
        return a.providerName.compareTo(b.providerName);
      }
      return a.mid.compareTo(b.mid);
    });
    return out;
  }

  /// How far ahead the trip is: booking late is the single biggest driver of
  /// airfare, so the model says so out loud.
  static double _flightAdvanceFactor(DateTime date) {
    final int d = _daysAhead(date);
    if (d <= 3) return 1.85;
    if (d <= 10) return 1.40;
    if (d <= 30) return 1.10;
    if (d <= 90) return 0.95;
    return 0.90;
  }

  static int _daysAhead(DateTime date) {
    final int d = date.difference(DateTime.now()).inDays;
    return d < 0 ? 0 : d;
  }
}

class _RideRate {
  const _RideRate({
    required this.base,
    required this.perKm,
    required this.perMin,
    required this.min,
  });
  final double base;
  final double perKm;
  final double perMin;
  final int min;
}

class _PlatformFactor {
  const _PlatformFactor(this.factor, this.fee, this.note);
  final double factor;
  final double fee;
  final String note;
}

class _Band {
  const _Band(this.low, this.high);
  final int low;
  final int high;
}
