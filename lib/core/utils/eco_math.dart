/// Pure Eco Score math (unit-testable).

class EcoMath {
  EcoMath._();

  /// Points per kilometer per travel mode. Walking and cycling are the
  /// zero-emission modes; public transport earns fewer points than
  /// active travel but still more than a private car (which earns 0).
  static const Map<String, double> pointsPerKm = <String, double>{
    'walk': 12,
    'cycle': 9,
    'transit': 6,
  };

  static const List<String> modes = <String>['walk', 'cycle', 'transit'];

  static String modeLabel(String mode) => switch (mode) {
        'walk' => 'Walking',
        'cycle' => 'Cycling',
        'transit' => 'Public transport',
        _ => mode,
      };

  static int activityPoints(String mode, double meters) {
    if (meters <= 0) return 0;
    final double per = pointsPerKm[mode] ?? 4;
    return (meters / 1000 * per).round() + 2; // +2 completion bonus
  }

  static const List<int> scoreLevels = <int>[0, 100, 250, 500];

  static const List<String> scoreLevelNames = <String>[
    'Trail Starter',
    'Green Traveler',
    'Eco Adventurer',
    'Carbon Champion',
  ];

  static int levelIndexFor(int score) {
    int idx = 0;
    for (int i = 0; i < scoreLevels.length; i++) {
      if (score >= scoreLevels[i]) idx = i;
    }
    return idx;
  }

  static String levelFor(int score) => scoreLevelNames[levelIndexFor(score)];

  /// 0..1 progress towards the next level.
  static double levelProgress(int score) {
    final int idx = levelIndexFor(score);
    if (idx >= scoreLevels.length - 1) return 1.0;
    final int base = scoreLevels[idx];
    final int next = scoreLevels[idx + 1];
    return ((score - base) / (next - base)).clamp(0.0, 1.0);
  }

  static const Map<String, (String, String, int)> badges = <String, (String, String, int)>{
    'first-steps': ('First Steps', 'Logged your first eco activity.', 0),
    'walk-1': ('Fresh Air', 'Walked a total of 1 km.', 0),
    'walk-10': ('City Stroller', 'Walked a total of 10 km.', 0),
    'cycle-25': ('Pedal Power', 'Cycled a total of 25 km.', 0),
    'transit-20': ('Rail Rider', 'Travelled 20 km by public transport.', 0),
    'score-100': ('Rising Star', 'Reached an Eco Score of 100.', 0),
    'score-250': ('Green Core', 'Reached an Eco Score of 250.', 0),
    'score-500': ('Carbon Champion', 'Reached an Eco Score of 500.', 0),
  };

  static List<String> badgesFor({
    required double walkKm,
    required double cycleKm,
    required double transitKm,
    required int score,
    required int sessions,
  }) {
    final List<String> out = <String>[];
    if (sessions >= 1) out.add('first-steps');
    if (walkKm >= 1) out.add('walk-1');
    if (walkKm >= 10) out.add('walk-10');
    if (cycleKm >= 25) out.add('cycle-25');
    if (transitKm >= 20) out.add('transit-20');
    if (score >= 100) out.add('score-100');
    if (score >= 250) out.add('score-250');
    if (score >= 500) out.add('score-500');
    return out;
  }
}
