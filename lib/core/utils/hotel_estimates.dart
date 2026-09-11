/// Honest, clearly-labelled estimated nightly price ranges (INR) for hotels
/// by star rating. Live prices change constantly and are not available from
/// any free source, so these are estimates for guidance only.
class HotelEstimates {
  HotelEstimates._();

  /// (low, high) INR per night for a hotel star rating, or null for unknown.
  static (int, int)? nightlyRangeByStars(int? stars) {
    if (stars == null || stars < 0) return null;
    if (stars >= 5) return (8000, 30000);
    if (stars == 4) return (4000, 12000);
    if (stars == 3) return (2000, 6000);
    if (stars == 2) return (1200, 3000);
    return (800, 2500);
  }

  static String rangeLabel(int? stars) {
    final (int, int)? r = nightlyRangeByStars(stars);
    if (r == null) return 'Price varies';
    return '₹${_inr(r.$1)} – ₹${_inr(r.$2)} / night (est.)';
  }

  static String _inr(int v) {
    final String s = v.toString();
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      b.write(s[i]);
      final int rem = s.length - 1 - i;
      if (rem > 0 && rem % 3 == 0) b.write(',');
    }
    return b.toString();
  }
}
