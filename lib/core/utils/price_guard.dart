// Deterministic, transparent reference-price engine for the Tourism
// "Payment Guardian".
//
// This intentionally NEVER accuses anyone of fraud. Every range is an honest,
// clearly-labelled *estimate* of what a service commonly costs in India, used
// only to flag prices that may be worth double-checking.

/// Broad service categories a tourist can check.
enum PriceCategory {
  taxi,
  auto,
  hotel,
  restaurant,
  guide,
  shopping,
  tickets,
  other,
}

extension PriceCategoryInfo on PriceCategory {
  /// Human label shown in the UI.
  String get label => switch (this) {
        PriceCategory.taxi => 'Taxi',
        PriceCategory.auto => 'Auto rickshaw',
        PriceCategory.hotel => 'Hotel',
        PriceCategory.restaurant => 'Restaurant',
        PriceCategory.guide => 'Guide',
        PriceCategory.shopping => 'Shopping',
        PriceCategory.tickets => 'Tickets',
        PriceCategory.other => 'Other',
      };

  /// What the reference is measured against (shown as a hint).
  String get unitHint => switch (this) {
        PriceCategory.taxi || PriceCategory.auto => 'per trip (per km)',
        PriceCategory.hotel => 'per night',
        PriceCategory.restaurant => 'per person',
        PriceCategory.guide => 'per day',
        PriceCategory.tickets => 'per person',
        PriceCategory.shopping || PriceCategory.other => '',
      };

  bool get distanceBased =>
      this == PriceCategory.taxi || this == PriceCategory.auto;
}

enum PriceVerdict {
  low,
  normal,
  potentiallyHigh,
  needsMoreInfo,
}

/// Outcome of a price check. [referenceText] and [rangeLow]/[rangeHigh] are
/// null when there is no reliable reference for the category.
class PriceCheckResult {
  const PriceCheckResult({
    required this.category,
    required this.amount,
    required this.verdict,
    required this.headline,
    required this.explanation,
    this.rangeLow,
    this.rangeHigh,
  });

  final PriceCategory category;
  final double amount;
  final PriceVerdict verdict;
  final String headline;
  final String explanation;
  final double? rangeLow;
  final double? rangeHigh;

  String get referenceText {
    final double? lo = rangeLow;
    final double? hi = rangeHigh;
    if (lo == null || hi == null) return '';
    return 'Reference range: ₹${_inr(lo)} – ₹${_inr(hi)}';
  }
}

/// Static engine — no I/O, no network, fully unit-testable.
class PriceGuard {
  PriceGuard._();

  /// Local (non-app) street rates in INR — clearly-labelled estimates:
  ///   Auto (local auto / e-rickshaw): ₹5 per km (minimum ₹10 → 2 km ≈ ₹10)
  ///   Taxi: ₹15 per km (minimum ₹40)
  static const double autoPerKm = 5;
  static const double autoMinimum = 10;
  static const double taxiPerKm = 15;
  static const double taxiMinimum = 40;

  static const double _loFactor = 0.7;
  static const double _hiFactor = 1.3;

  /// Expected local auto fare for a trip of [km] kilometres.
  static double estimateAuto(double km) {
    if (km <= 0) return 0;
    final double fare = autoPerKm * km;
    return _roundTo5(fare < autoMinimum ? autoMinimum : fare);
  }

  /// Expected local taxi fare for a trip of [km] kilometres.
  static double estimateTaxi(double km) {
    if (km <= 0) return 0;
    final double fare = taxiPerKm * km;
    return _roundTo5(fare < taxiMinimum ? taxiMinimum : fare);
  }

  static double _roundTo5(double v) => (v / 5).round() * 5.0;

  static PriceCheckResult check({
    required PriceCategory category,
    required double amount,
    double? distanceKm,
  }) {
    if (category.distanceBased && (distanceKm == null || distanceKm <= 0)) {
      return PriceCheckResult(
        category: category,
        amount: amount,
        verdict: PriceVerdict.needsMoreInfo,
        headline: 'Add the distance',
        explanation:
            '${category.label} fares are metered per kilometre. Enter the '
            'trip distance (or estimate it from your locations) so Tourism '
            'can show the expected range.',
      );
    }

    if (category.distanceBased) {
      final double expected = category == PriceCategory.taxi
          ? estimateTaxi(distanceKm!)
          : estimateAuto(distanceKm!);
      return _judge(category, amount, expected * _loFactor, expected * _hiFactor);
    }

    final (double lo, double hi)? ref = _flatReference(category);
    if (ref == null) {
      return PriceCheckResult(
        category: category,
        amount: amount,
        verdict: PriceVerdict.needsMoreInfo,
        headline: 'No standard reference',
        explanation:
            '${category.label} prices depend heavily on the specific item or '
            'service, so there is no reliable reference to compare against. '
            'Compare a second quote or ask what is included before paying.',
      );
    }
    return _judge(category, amount, ref.$1, ref.$2);
  }

  static PriceCheckResult _judge(
    PriceCategory category,
    double amount,
    double lo,
    double hi,
  ) {
    if (amount < lo) {
      return PriceCheckResult(
        category: category,
        amount: amount,
        verdict: PriceVerdict.low,
        headline: 'Unusually low',
        rangeLow: lo,
        rangeHigh: hi,
        explanation:
            'This is below the typical ${category.label} range. It may be a '
            'promo, a shared ride or a partial charge — confirm exactly what '
            'is included before paying.',
      );
    }
    if (amount <= hi) {
      return PriceCheckResult(
        category: category,
        amount: amount,
        verdict: PriceVerdict.normal,
        headline: 'Looks within the typical range',
        rangeLow: lo,
        rangeHigh: hi,
        explanation:
            'This amount is inside the common range for a ${category.label}. '
            'This is an estimate, not proof of overcharging.',
      );
    }
    return PriceCheckResult(
      category: category,
      amount: amount,
      verdict: PriceVerdict.potentiallyHigh,
      headline: 'Potentially high',
      rangeLow: lo,
      rangeHigh: hi,
      explanation:
          'This amount may be higher than the expected range for a '
          '${category.label}. This is an estimate, not proof of overcharging '
          '— ask for a breakdown or compare another quote before concluding '
          'anything.',
    );
  }

  /// (low, high) INR references for non-metered categories, or null when no
  /// honest reference exists.
  static (double, double)? _flatReference(PriceCategory category) =>
      switch (category) {
        PriceCategory.hotel => (800.0, 6000.0),
        PriceCategory.restaurant => (120.0, 1500.0),
        PriceCategory.guide => (300.0, 2500.0),
        PriceCategory.tickets => (20.0, 1500.0),
        _ => null,
      };
}

String _inr(double v) {
  final int n = v.round();
  final String s = n.toString();
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    b.write(s[i]);
    final int rem = s.length - 1 - i;
    if (rem > 0 && rem % 3 == 0) b.write(',');
  }
  return b.toString();
}
