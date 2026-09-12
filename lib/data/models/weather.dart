// OpenWeather data (proxied through the Tourism backend).

class WeatherCurrent {
  WeatherCurrent({
    required this.tempC,
    required this.feelsLikeC,
    required this.humidityPct,
    required this.windMs,
    required this.windDeg,
    required this.condition,
    required this.icon,
    required this.pressureHpa,
    required this.visibilityM,
    required this.updatedAt,
  });

  final double tempC;
  final double feelsLikeC;
  final int humidityPct;
  final double windMs;
  final double windDeg;
  final String condition;
  final String icon;
  final int pressureHpa;
  final double visibilityM;
  final DateTime updatedAt;

  factory WeatherCurrent.fromJson(Map<String, dynamic> m) => WeatherCurrent(
        tempC: (m['tempC'] as num?)?.toDouble() ?? 0,
        feelsLikeC: (m['feelsLikeC'] as num?)?.toDouble() ?? 0,
        humidityPct: (m['humidityPct'] as num?)?.toInt() ?? 0,
        windMs: (m['windMs'] as num?)?.toDouble() ?? 0,
        windDeg: (m['windDeg'] as num?)?.toDouble() ?? 0,
        condition: (m['condition'] as String?) ?? 'Unknown',
        icon: (m['icon'] as String?) ?? '01d',
        pressureHpa: (m['pressureHpa'] as num?)?.toInt() ?? 0,
        visibilityM: (m['visibilityM'] as num?)?.toDouble() ?? 0,
        updatedAt: DateTime.tryParse(m['updatedAt'] ?? '') ?? DateTime.now(),
      );
}

class ForecastDay {
  ForecastDay({
    required this.date,
    required this.tempMaxC,
    required this.tempMinC,
    required this.condition,
    required this.icon,
    required this.precipChancePct,
  });

  final DateTime date;
  final double tempMaxC;
  final double tempMinC;
  final String condition;
  final String icon;
  final int precipChancePct;

  factory ForecastDay.fromJson(Map<String, dynamic> m) => ForecastDay(
        date: DateTime.tryParse(m['date'] ?? '') ?? DateTime.now(),
        tempMaxC: (m['tempMaxC'] as num?)?.toDouble() ?? 0,
        tempMinC: (m['tempMinC'] as num?)?.toDouble() ?? 0,
        condition: (m['condition'] as String?) ?? 'Unknown',
        icon: (m['icon'] as String?) ?? '01d',
        precipChancePct: (m['precipChancePct'] as num?)?.toInt() ?? 0,
      );
}

/// Derive practical safety notes from current conditions.
/// Pure function so it can be unit tested.
List<String> weatherSafetyNotes(WeatherCurrent w) {
  final List<String> notes = <String>[];
  if (w.tempC >= 38) {
    notes.add(
      'Extreme heat: limit outdoor activity to early morning, drink water often and look for shade.',
    );
  } else if (w.tempC >= 32) {
    notes.add('Hot day: carry water and use sun protection outdoors.');
  }
  if (w.tempC <= 0) {
    notes.add('Freezing temperatures: dress in layers and watch for icy surfaces.');
  } else if (w.tempC <= 5) {
    notes.add('Cold day: layered clothing is recommended.');
  }
  final double windMsToKmh = (w.windMs * 3.6 * 10).round() / 10;
  if (windMsToKmh >= 40) {
    notes.add('Strong winds: avoid open areas, loose signage and water bodies.');
  } else if (windMsToKmh >= 25) {
    notes.add('Windy conditions: mind loose items and narrow bridges.');
  }
  if (w.humidityPct >= 80 && w.tempC >= 28) {
    notes.add('High heat index: take extra breaks during walks.');
  }
  if (w.visibilityM < 1000) {
    notes.add('Reduced visibility: extra caution while moving around.');
  }
  if (notes.isEmpty) {
    notes.add('Conditions look comfortable for outdoor sightseeing.');
  }
  return notes;
}

/// A single, honest travel recommendation for today, derived only from the
/// current conditions and (when available) the day's rain probability.
/// Never invents data — when nothing is actionable, returns a neutral line.
String weatherTravelAdvice(WeatherCurrent w, {ForecastDay? today}) {
  final int rainPct = today?.precipChancePct ?? -1;
  if (rainPct >= 60) {
    return 'High chance of rain ($rainPct%) — carry an umbrella and keep '
        'outdoor plans flexible.';
  }
  if (rainPct >= 30) {
    return 'A $rainPct% chance of rain today — pack a light rain jacket.';
  }
  if (w.tempC >= 38) {
    return 'Extreme heat today — plan sightseeing for early morning or evening.';
  }
  if (w.tempC >= 32) {
    return 'Hot day — carry water and prefer shaded, indoor attractions midday.';
  }
  if (w.tempC <= 5) {
    return 'Cold day — dress in layers for comfortable sightseeing.';
  }
  if ((w.windMs * 3.6) >= 25) {
    return 'Windy today — mind hats, umbrellas and open-air viewpoints.';
  }
  if (w.humidityPct >= 80) {
    return 'Humid day — take breaks and stay hydrated while exploring.';
  }
  return 'Good day for outdoor sightseeing — conditions look comfortable.';
}
