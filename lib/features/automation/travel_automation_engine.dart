import '../../data/models/trip_plan.dart';

enum TravelAutomationKind {
  packing,
  documents,
  bookingReview,
  weatherCheck,
  vehicleReadiness,
  departureBrief,
  morningBrief,
  hotelCheckIn,
  essentialsCheck,
  hydration,
  budgetPulse,
  returnBeforeDark,
  safetyCheckIn,
  photoBackup,
  tripWrap,
}

enum AutomationPhase { beforeTrip, duringTrip, afterTrip }

class AutomationDefinition {
  const AutomationDefinition({
    required this.kind,
    required this.title,
    required this.description,
    required this.phase,
  });

  final TravelAutomationKind kind;
  final String title;
  final String description;
  final AutomationPhase phase;
}

class AutomationEvent {
  const AutomationEvent({
    required this.at,
    required this.title,
    required this.body,
  });

  final DateTime at;
  final String title;
  final String body;
}

class TravelAutomationEngine {
  TravelAutomationEngine._();

  static const List<AutomationDefinition> definitions = <AutomationDefinition>[
    AutomationDefinition(
      kind: TravelAutomationKind.packing,
      title: 'Smart packing trigger',
      description: 'Starts the packing check two evenings before departure.',
      phase: AutomationPhase.beforeTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.documents,
      title: 'Document readiness',
      description: 'Prompts a passport, ID, ticket and booking-vault review.',
      phase: AutomationPhase.beforeTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.bookingReview,
      title: 'Booking confirmation audit',
      description: 'Reminds you to verify official provider confirmations and PNRs.',
      phase: AutomationPhase.beforeTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.weatherCheck,
      title: 'Weather re-check',
      description: 'Runs a final weather reminder the evening before travel.',
      phase: AutomationPhase.beforeTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.vehicleReadiness,
      title: 'Vehicle readiness',
      description: 'Prompts fuel, tyre, documents and charging checks when relevant.',
      phase: AutomationPhase.beforeTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.departureBrief,
      title: 'Departure morning brief',
      description: 'Surfaces route, weather, documents and booking checks at 7 AM.',
      phase: AutomationPhase.beforeTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.morningBrief,
      title: 'Daily itinerary brief',
      description: 'Provides a 7 AM plan prompt on every trip day.',
      phase: AutomationPhase.duringTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.hotelCheckIn,
      title: 'Stay check-in assistant',
      description: 'Prompts hotel address, ID and confirmation at 1 PM on day one.',
      phase: AutomationPhase.duringTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.essentialsCheck,
      title: 'Nearby essentials check',
      description: 'Reminds you to locate water, pharmacy, ATM and fuel nearby.',
      phase: AutomationPhase.duringTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.hydration,
      title: 'Hydration rhythm',
      description: 'Schedules three lightweight hydration prompts per trip day.',
      phase: AutomationPhase.duringTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.budgetPulse,
      title: 'Daily budget pulse',
      description: 'Prompts an expense review each evening before spending drifts.',
      phase: AutomationPhase.duringTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.returnBeforeDark,
      title: 'Daylight return guard',
      description: 'Prompts a route and safety check before evening travel.',
      phase: AutomationPhase.duringTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.safetyCheckIn,
      title: 'Night safety check-in',
      description: 'Prompts SOS-contact and live-sharing readiness every night.',
      phase: AutomationPhase.duringTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.photoBackup,
      title: 'Photo and document backup',
      description: 'Schedules a nightly reminder to secure important trip media.',
      phase: AutomationPhase.duringTrip,
    ),
    AutomationDefinition(
      kind: TravelAutomationKind.tripWrap,
      title: 'Trip closure assistant',
      description: 'Prompts final expenses, booking references and document cleanup.',
      phase: AutomationPhase.afterTrip,
    ),
  ];

  static List<AutomationEvent> eventsFor({
    required TravelAutomationKind kind,
    required TripPlan trip,
    required DateTime now,
  }) {
    final DateTime start = _at(trip.startDate, 0);
    final int days = trip.days.clamp(1, 14);
    final DateTime end = start.add(Duration(days: days));
    final List<AutomationEvent> out = <AutomationEvent>[];

    void one(DateTime at, String title, String body) {
      if (at.isAfter(now.add(const Duration(minutes: 1)))) {
        out.add(AutomationEvent(at: at, title: title, body: body));
      }
    }

    void daily(int hour, int minute, String title, String body) {
      for (int day = 0; day < days; day++) {
        one(_at(start.add(Duration(days: day)), hour, minute), title, body);
      }
    }

    switch (kind) {
      case TravelAutomationKind.packing:
        one(_at(start.subtract(const Duration(days: 2)), 19),
            'Packing check for ${trip.destination}',
            'Open Smart Packing, tick essentials and add destination-specific items.');
      case TravelAutomationKind.documents:
        one(_at(start.subtract(const Duration(days: 3)), 10),
            'Travel documents check',
            'Review IDs, tickets, insurance and expiry dates in your secure vault.');
      case TravelAutomationKind.bookingReview:
        one(_at(start.subtract(const Duration(days: 4)), 11),
            'Verify official booking confirmations',
            'Check provider status, PNR/reference and cancellation terms.');
      case TravelAutomationKind.weatherCheck:
        one(_at(start.subtract(const Duration(days: 1)), 18),
            'Re-check ${trip.destination} weather',
            'Adjust clothes, departure buffer and outdoor plans using fresh weather.');
      case TravelAutomationKind.vehicleReadiness:
        one(_at(start.subtract(const Duration(days: 1)), 9),
            'Vehicle readiness check',
            'Check fuel or charge, tyres, licence, insurance and emergency kit.');
      case TravelAutomationKind.departureBrief:
        one(_at(start, 7), 'Departure brief: ${trip.destination}',
            'Review route, weather, documents and confirmed bookings before leaving.');
      case TravelAutomationKind.morningBrief:
        daily(7, 0, 'Today in ${trip.destination}',
            'Review today’s stops, opening hours, weather and realistic travel time.');
      case TravelAutomationKind.hotelCheckIn:
        one(_at(start, 13), 'Stay check-in preparation',
            'Keep the official confirmation, hotel address and accepted ID ready.');
      case TravelAutomationKind.essentialsCheck:
        one(_at(start, 10), 'Locate nearby essentials',
            'Save a nearby pharmacy, water point, ATM and transport pickup.');
      case TravelAutomationKind.hydration:
        daily(10, 30, 'Hydration check', 'Drink water and refill before the next stop.');
        daily(14, 30, 'Hydration check', 'Pause, hydrate and check heat exposure.');
        daily(18, 0, 'Hydration check', 'Refill water before evening travel.');
      case TravelAutomationKind.budgetPulse:
        daily(20, 0, 'Daily travel budget pulse',
            'Record today’s real expenses and compare them with your budget.');
      case TravelAutomationKind.returnBeforeDark:
        daily(17, 15, 'Evening route safety check',
            'Check sunset conditions, return route, battery and live sharing.');
      case TravelAutomationKind.safetyCheckIn:
        daily(21, 0, 'Night safety check-in',
            'Confirm your SOS contact, current location and next safe route.');
      case TravelAutomationKind.photoBackup:
        daily(22, 0, 'Secure today’s trip media',
            'Back up important photos, receipts and document scans on your chosen storage.');
      case TravelAutomationKind.tripWrap:
        one(_at(end, 19), 'Close out ${trip.destination}',
            'Finish expenses, save booking references and review stored documents.');
    }
    out.sort((AutomationEvent a, AutomationEvent b) => a.at.compareTo(b.at));
    return out;
  }

  static DateTime _at(DateTime day, int hour, [int minute = 0]) =>
      DateTime(day.year, day.month, day.day, hour, minute);
}
