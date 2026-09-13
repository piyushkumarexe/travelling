/// Pragmatic parser for the subset of OSM `opening_hours` values that
/// appear on nearby POIs. Honest by design: anything it cannot confidently
/// parse returns null and the UI shows "Opening hours unavailable" instead
/// of pretending the place is open.
library;

/// Parsed opening hours for a place.
class OpeningHours {
  const OpeningHours._(this.ranges, this.alwaysOpen);

  /// Per-weekday minute-ranges: key 1=Mon … 7=Sun (ISO-8601 like DateTime).
  final Map<int, List<(int, int)>> ranges;

  /// `24/7`.
  final bool alwaysOpen;

  /// Returns when the place closes (for [when]'s day), or null when it does
  /// not close that day (e.g. 24/7 or no range matches → unknown is NOT
  /// returned here; callers check [appliesTo] first).
  DateTime? closesAt(DateTime when) {
    if (alwaysOpen) return null;
    final List<(int, int)>? r = ranges[when.weekday];
    if (r == null || r.isEmpty) return null;
    (int, int)? latest = r.first;
    for (final (int, int) span in r) {
      if (span.$2 >= latest.$2) latest = span;
    }
    return DateTime(when.year, when.month, when.day, latest.$2 ~/ 60,
        latest.$2 % 60);
  }

  /// True when the parser found rules for [when]'s weekday.
  bool appliesTo(DateTime when) => alwaysOpen || ranges[when.weekday] != null;
}

int? _minutes(String hhmm) {
  final RegExp m = RegExp(r'^(\d{1,2}):(\d{2})$');
  final RegExpMatch? match = m.firstMatch(hhmm.trim());
  if (match == null) return null;
  final int hh = int.parse(match.group(1)!);
  final int mm = int.parse(match.group(2)!);
  if (hh > 24 || mm > 59) return null;
  return hh * 60 + mm;
}

int? _weekday(String token) {
  const Map<String, int> days = <String, int>{
    'mo': 1, 'tu': 2, 'we': 3, 'th': 4, 'fr': 5, 'sa': 6, 'su': 7,
  };
  return days[token.trim().toLowerCase().substring(0, 2)];
}

/// Parses common OSM opening_hours values: `24/7`, `Mo-Su 09:00-21:00`,
/// `Mo-Fr 10:00-20:00; Sa,Su 11:00-22:00`, `Mo-Sa 09:00-13:00,16:00-21:00`.
/// Returns null for anything else (public holidays, sunrise/sunset, …).
OpeningHours? parseOpeningHours(String? raw) {
  final String v = (raw ?? '').trim();
  if (v.isEmpty) return null;
  if (v == '24/7') return const OpeningHours._(<int, List<(int, int)>>{}, true);

  final Map<int, List<(int, int)>> out = <int, List<(int, int)>>{};
  for (final String part in v.split(';')) {
    final String rule = part.trim();
    if (rule.isEmpty) continue;
    // Split "Mo-Fr 10:00-20:00" / "Sa,Su 11:00-22:00" / "09:00-21:00".
    final RegExp daysRe = RegExp(r'^([A-Za-z,\- ]+)\s+(.*)$');
    String daysPart = '';
    String timesPart = rule;
    final RegExpMatch? dm = daysRe.firstMatch(rule);
    if (dm != null && dm.group(2)!.contains(':')) {
      daysPart = dm.group(1)!.trim();
      timesPart = dm.group(2)!.trim();
    }
    final List<(int, int)> spans = <(int, int)>[];
    for (final String tp in timesPart.split(',')) {
      final RegExp rangeRe = RegExp(r'^(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})$');
      final RegExpMatch? rm = rangeRe.firstMatch(tp.trim());
      if (rm == null) return null; // unsupported syntax → unknown
      final int? start = _minutes(rm.group(1)!);
      final int? end = _minutes(rm.group(2)!);
      if (start == null || end == null || end <= start) return null;
      spans.add((start, end));
    }
    if (spans.isEmpty) return null;
    List<int> days = <int>[];
    if (daysPart.isEmpty) {
      days = <int>[1, 2, 3, 4, 5, 6, 7]; // bare times apply daily
    } else {
      for (final String chunk in daysPart.split(',')) {
        final String c = chunk.trim();
        if (c.contains('-')) {
          final List<String> ab = c.split('-');
          final int? a = _weekday(ab.first);
          final int? b = _weekday(ab.last);
          if (a == null || b == null) return null;
          if (a <= b) {
            for (int d = a; d <= b; d++) {
              days.add(d);
            }
          } else {
            for (int d = a; d <= 7; d++) {
              days.add(d);
            }
            for (int d = 1; d <= b; d++) {
              days.add(d);
            }
          }
        } else {
          final int? d = _weekday(c);
          if (d == null) return null;
          days.add(d);
        }
      }
    }
    for (final int d in days) {
      out.putIfAbsent(d, () => <(int, int)>[]).addAll(spans);
    }
  }
  if (out.isEmpty) return null;
  return OpeningHours._(out, false);
}
