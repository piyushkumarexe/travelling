import 'dart:math' as math;

/// Pure, deterministic logic for the five offline Traveller Toolkit features.
/// Keeping it out of widgets makes every calculation unit-testable and usable
/// without network, Firebase or a logged-in account.
class TravellerToolkitEngine {
  TravellerToolkitEngine._();

  // -----------------------------------------------------------------------
  // 1. SMART PACKING
  // -----------------------------------------------------------------------

  static List<PackingItem> packingList({
    required int days,
    required TripStyle style,
    required Climate climate,
  }) {
    final int safeDays = days.clamp(1, 60);
    final Map<String, PackingItem> out = <String, PackingItem>{};
    void add(String name, String category, {int quantity = 1}) {
      out[name] = PackingItem(
        name: name,
        category: category,
        quantity: quantity,
      );
    }

    add('Government ID / passport', 'Documents');
    add('Tickets & booking confirmations', 'Documents');
    add('Emergency contacts (offline copy)', 'Documents');
    add('Wallet, cards & some cash', 'Documents');
    add('Phone', 'Tech');
    add('Phone charger', 'Tech');
    add('Power bank', 'Tech');
    add('Daily medicines', 'Health', quantity: safeDays);
    add('Small first-aid kit', 'Health');
    add('Reusable water bottle', 'Health');
    add('Toothbrush & toiletries', 'Personal');
    add('Underwear', 'Clothes', quantity: math.min(safeDays + 1, 8));
    add('Socks', 'Clothes', quantity: math.min(safeDays + 1, 8));
    add('Tops / shirts', 'Clothes', quantity: math.max(2, (safeDays / 2).ceil()));
    add('Bottoms', 'Clothes', quantity: math.max(1, (safeDays / 3).ceil()));
    add('Sleepwear', 'Clothes');
    add('Comfortable walking shoes', 'Clothes');

    if (safeDays >= 5) add('Laundry bag / detergent sheets', 'Personal');
    if (safeDays >= 8) add('Nail clipper / grooming kit', 'Personal');

    switch (climate) {
      case Climate.hot:
        add('Sunscreen SPF 30+', 'Weather');
        add('Cap / sun hat', 'Weather');
        add('Sunglasses', 'Weather');
        add('ORS / electrolyte sachets', 'Health', quantity: math.min(safeDays, 5));
      case Climate.cold:
        add('Warm jacket', 'Weather');
        add('Thermal base layer', 'Weather', quantity: math.max(1, safeDays ~/ 3));
        add('Gloves & warm cap', 'Weather');
        add('Lip balm / moisturiser', 'Health');
      case Climate.rainy:
        add('Compact umbrella', 'Weather');
        add('Rain jacket / poncho', 'Weather');
        add('Waterproof shoe cover', 'Weather');
        add('Zip pouches for electronics', 'Tech');
      case Climate.mixed:
        add('Light layer / jacket', 'Weather');
        add('Compact umbrella', 'Weather');
        add('Sunscreen SPF 30+', 'Weather');
    }

    switch (style) {
      case TripStyle.leisure:
        add('Camera / memory card', 'Tech');
        add('Day bag', 'Personal');
      case TripStyle.business:
        add('Laptop & charger', 'Tech');
        add('Formal outfit', 'Clothes', quantity: math.max(1, (safeDays / 2).ceil()));
        add('Business cards / meeting notes', 'Documents');
        add('HDMI / presentation adapter', 'Tech');
      case TripStyle.adventure:
        add('Quick-dry clothes', 'Clothes', quantity: math.max(2, safeDays ~/ 2));
        add('Torch / headlamp', 'Tech');
        add('Insect repellent', 'Health');
        add('Trail snacks', 'Health', quantity: safeDays);
        add('Offline map downloaded', 'Documents');
      case TripStyle.family:
        add('Children / senior medicines', 'Health');
        add('Wet wipes & tissues', 'Personal');
        add('Snacks for the journey', 'Health');
        add('Small games / entertainment', 'Personal');
    }

    final List<PackingItem> list = out.values.toList()
      ..sort((PackingItem a, PackingItem b) {
        final int c = a.category.compareTo(b.category);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
    return list;
  }

  // -----------------------------------------------------------------------
  // 2. COUNTDOWN + DEPARTURE READINESS
  // -----------------------------------------------------------------------

  static CountdownResult countdown(DateTime now, DateTime departure) {
    final Duration d = departure.difference(now);
    if (d.isNegative) {
      return CountdownResult(
        duration: d,
        headline: 'Departure time passed',
        urgency: CountdownUrgency.passed,
      );
    }
    final CountdownUrgency urgency = d.inHours < 6
        ? CountdownUrgency.now
        : d.inHours < 24
            ? CountdownUrgency.today
            : d.inDays <= 3
                ? CountdownUrgency.soon
                : CountdownUrgency.planned;
    final String headline = d.inDays >= 1
        ? '${d.inDays}d ${d.inHours % 24}h to go'
        : '${d.inHours}h ${d.inMinutes % 60}m to go';
    return CountdownResult(duration: d, headline: headline, urgency: urgency);
  }

  static List<DepartureTask> departureTasks(DateTime now, DateTime departure) {
    final Duration left = departure.difference(now);
    return <DepartureTask>[
      DepartureTask('Check ticket / PNR status', left <= const Duration(days: 2)),
      DepartureTask('Download offline tickets & maps',
          left <= const Duration(days: 3)),
      DepartureTask('Check weather and pack final layer',
          left <= const Duration(days: 1)),
      DepartureTask('Confirm hotel check-in and transport',
          left <= const Duration(days: 2)),
      DepartureTask('Charge phone and power bank',
          left <= const Duration(hours: 12)),
      DepartureTask('Leave with traffic/security buffer',
          left <= const Duration(hours: 6)),
    ];
  }

  // -----------------------------------------------------------------------
  // 3. GROUP BUDGET SPLITTER
  // -----------------------------------------------------------------------

  static BudgetSplit splitBudget({
    required double total,
    required int travellers,
    required int days,
  }) {
    final double safeTotal = math.max(0, total);
    final int people = travellers.clamp(1, 100);
    final int tripDays = days.clamp(1, 365);
    return BudgetSplit(
      total: safeTotal,
      travellers: people,
      days: tripDays,
      stay: safeTotal * 0.35,
      transport: safeTotal * 0.25,
      food: safeTotal * 0.20,
      activities: safeTotal * 0.10,
      emergencyBuffer: safeTotal * 0.10,
    );
  }

  // -----------------------------------------------------------------------
  // 4. INDIA PHRASEBOOK
  // -----------------------------------------------------------------------

  static const List<TravelPhrase> phrases = <TravelPhrase>[
    TravelPhrase('Hello / Namaste', 'नमस्ते', 'Namaste', 'Basics'),
    TravelPhrase('Thank you', 'धन्यवाद', 'Dhanyavaad', 'Basics'),
    TravelPhrase('Please', 'कृपया', 'Kripya', 'Basics'),
    TravelPhrase('Yes / No', 'हाँ / नहीं', 'Haan / Nahin', 'Basics'),
    TravelPhrase('How much does this cost?', 'यह कितने का है?',
        'Yeh kitne ka hai?', 'Shopping'),
    TravelPhrase('Please use the meter', 'कृपया मीटर चलाइए',
        'Kripya meter chalaiye', 'Transport'),
    TravelPhrase('Take me to this address', 'मुझे इस पते पर ले चलिए',
        'Mujhe is pate par le chaliye', 'Transport'),
    TravelPhrase('Please stop here', 'कृपया यहाँ रोकिए',
        'Kripya yahaan rokiye', 'Transport'),
    TravelPhrase('Where is the toilet?', 'शौचालय कहाँ है?',
        'Shauchalay kahaan hai?', 'Essentials'),
    TravelPhrase('No onion / garlic', 'बिना प्याज़ / लहसुन के',
        'Bina pyaaz / lehsun ke', 'Food'),
    TravelPhrase('I have an allergy', 'मुझे एलर्जी है',
        'Mujhe allergy hai', 'Health'),
    TravelPhrase('I need a doctor', 'मुझे डॉक्टर चाहिए',
        'Mujhe doctor chahiye', 'Emergency'),
    TravelPhrase('Please call the police', 'कृपया पुलिस को बुलाइए',
        'Kripya police ko bulaiye', 'Emergency'),
    TravelPhrase('I am lost', 'मैं रास्ता भूल गया / गई हूँ',
        'Main raasta bhool gaya / gayi hoon', 'Emergency'),
    TravelPhrase('Is it safe to go there?', 'क्या वहाँ जाना सुरक्षित है?',
        'Kya vahaan jaana surakshit hai?', 'Safety'),
    TravelPhrase('Can I pay by UPI?', 'क्या मैं UPI से भुगतान कर सकता हूँ?',
        'Kya main UPI se bhugtaan kar sakta hoon?', 'Shopping'),
  ];

  static List<TravelPhrase> searchPhrases(String query) {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return phrases;
    return phrases
        .where((TravelPhrase p) =>
            p.english.toLowerCase().contains(q) ||
            p.hindi.toLowerCase().contains(q) ||
            p.roman.toLowerCase().contains(q) ||
            p.category.toLowerCase().contains(q))
        .toList();
  }

  // -----------------------------------------------------------------------
  // 5. TRAVEL UNIT CONVERTER
  // -----------------------------------------------------------------------

  static double convert(double value, Conversion conversion) =>
      switch (conversion) {
        Conversion.kmToMiles => value * 0.621371,
        Conversion.milesToKm => value / 0.621371,
        Conversion.celsiusToFahrenheit => value * 9 / 5 + 32,
        Conversion.fahrenheitToCelsius => (value - 32) * 5 / 9,
        Conversion.kgToLb => value * 2.2046226218,
        Conversion.lbToKg => value / 2.2046226218,
        Conversion.litresToGallons => value * 0.2641720524,
        Conversion.gallonsToLitres => value / 0.2641720524,
        Conversion.kmplToMpg => value * 2.35214583,
        Conversion.mpgToKmpl => value / 2.35214583,
      };
}

enum TripStyle { leisure, business, adventure, family }

enum Climate { hot, cold, rainy, mixed }

extension TripStyleInfo on TripStyle {
  String get label => switch (this) {
        TripStyle.leisure => 'Leisure',
        TripStyle.business => 'Business',
        TripStyle.adventure => 'Adventure',
        TripStyle.family => 'Family',
      };
}

extension ClimateInfo on Climate {
  String get label => switch (this) {
        Climate.hot => 'Hot',
        Climate.cold => 'Cold',
        Climate.rainy => 'Rainy',
        Climate.mixed => 'Mixed',
      };
}

class PackingItem {
  const PackingItem({
    required this.name,
    required this.category,
    this.quantity = 1,
  });

  final String name;
  final String category;
  final int quantity;

  String get id => '$category::$name';
  String get displayName => quantity > 1 ? '$name × $quantity' : name;
}

enum CountdownUrgency { planned, soon, today, now, passed }

class CountdownResult {
  const CountdownResult({
    required this.duration,
    required this.headline,
    required this.urgency,
  });
  final Duration duration;
  final String headline;
  final CountdownUrgency urgency;
}

class DepartureTask {
  const DepartureTask(this.title, this.dueNow);
  final String title;
  final bool dueNow;
}

class BudgetSplit {
  const BudgetSplit({
    required this.total,
    required this.travellers,
    required this.days,
    required this.stay,
    required this.transport,
    required this.food,
    required this.activities,
    required this.emergencyBuffer,
  });

  final double total;
  final int travellers;
  final int days;
  final double stay;
  final double transport;
  final double food;
  final double activities;
  final double emergencyBuffer;

  double get perPerson => total / travellers;
  double get perPersonPerDay => total / travellers / days;
  double get allocated => stay + transport + food + activities + emergencyBuffer;
}

class TravelPhrase {
  const TravelPhrase(this.english, this.hindi, this.roman, this.category);
  final String english;
  final String hindi;
  final String roman;
  final String category;
}

enum Conversion {
  kmToMiles('Kilometres', 'Miles'),
  milesToKm('Miles', 'Kilometres'),
  celsiusToFahrenheit('°C', '°F'),
  fahrenheitToCelsius('°F', '°C'),
  kgToLb('Kilograms', 'Pounds'),
  lbToKg('Pounds', 'Kilograms'),
  litresToGallons('Litres', 'US gallons'),
  gallonsToLitres('US gallons', 'Litres'),
  kmplToMpg('km/L', 'US mpg'),
  mpgToKmpl('US mpg', 'km/L');

  const Conversion(this.from, this.to);
  final String from;
  final String to;

  String get label => '$from → $to';
}
