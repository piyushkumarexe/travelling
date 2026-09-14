import 'package:flutter/foundation.dart';

/// 🧳 TRAVEL BOOKING HUB — provider registry.
///
/// Every entry here uses an OFFICIAL, verified flow only:
/// - Uber: official deep links documented at developer.uber.com/docs/deep-linking
///   (universal link https://m.uber.com/ul/?action=setPickup&pickup[latitude]=…
///   opens the Uber app when installed, else Uber's mobile web booking).
/// - Ola: official out-of-app flow documented at developers.olacabs.com
///   (https://book.olacabs.com/?lat=…&lng=…&drop_lat=…&drop_lng=…).
/// - Rapido: NO public documented deep link exists → the official app
///   (com.rapido.passenger, Google Play verified) is launched directly;
///   the Play Store listing is the fallback. Locations are NOT prefilled.
/// - IRCTC: official app (cris.org.in.prs.ima) + official website.
/// - RedBus / Zoomcar / Headout / Klook / Goibibo: official websites only
///   (no verified query handoff → never claimed).
/// - MakeMyTrip flights: the official public search URL pattern the site
///   itself generates (itinerary=FROM-TO-dd/mm/yyyy&tripType&paxType&cabinClass).
/// - Booking.com hotels: official searchresults.html parameters
///   (ss, checkin, checkout, group_adults, no_rooms).
///
/// Nothing here scrapes, reverse-engineers or invents URLs. A provider with
/// an unverified link is NOT added. Adding a future official API integration
/// means implementing [BookingApi] — no UI rewrite.

enum BookingCategory {
  ride('Ride', '🚕'),
  flight('Flight', '✈️'),
  train('Train', '🚆'),
  bus('Bus', '🚌'),
  hotel('Hotel/Stay', '🏨'),
  carRental('Car Rental', '🚗'),
  activities('Activities', '🎟️');

  const BookingCategory(this.label, this.emoji);
  final String label;
  final String emoji;
}

/// Location handoff format the provider officially supports.
enum LocationFormat { latLng, none }

/// The normalized booking search the user built in the form.
@immutable
class BookingQuery {
  const BookingQuery({
    this.fromName,
    this.fromLat,
    this.fromLng,
    this.toName,
    this.toLat,
    this.toLng,
    this.date, // yyyy-MM-dd
    this.returnDate, // yyyy-MM-dd
    this.passengers = 1,
    this.travelClass, // E / premium etc (flight)
    this.rooms = 1,
    this.serviceType, // bike | auto | cab (ride)
    this.tripType = 'O', // O | R (flight)
  });

  final String? fromName;
  final double? fromLat;
  final double? fromLng;
  final String? toName;
  final double? toLat;
  final double? toLng;
  final String? date;
  final String? returnDate;
  final int passengers;
  final String? travelClass;
  final int rooms;
  final String? serviceType;
  final String tripType;

  bool get hasFrom => fromLat != null && fromLng != null;
  bool get hasTo => toLat != null && toLng != null;
}

/// A booking provider with its verified official entry points.
@immutable
class BookingProvider {
  const BookingProvider({
    required this.providerId,
    required this.providerName,
    required this.category,
    required this.emoji,
    required this.locationFormat,
    this.appDeepLinkBuilder, // verified native-scheme deep link (opens the app)
    this.appLaunchPackage, // verified Android package for app-launch intent
    this.webLinkBuilder, // verified https link with prefill (app or mobile web)
    this.plainWebUrl, // verified official website (no prefill)
    this.playStoreUrl, // verified official listing (fallback install path)
    this.appSchemePrefillsLocation = false, // scheme carries pickup/drop
    this.handoffNote = '',
  });

  final String providerId;
  final String providerName;
  final BookingCategory category;
  final String emoji;

  /// Builds the VERIFIED official deep/universal link (may open the provider
  /// app via App Links, else the provider's mobile web).
  final String Function(BookingQuery q)? appDeepLinkBuilder;
  final String Function(BookingQuery q)? webLinkBuilder;
  final bool appSchemePrefillsLocation;

  /// Verified Android package name — the app is launched directly via an
  /// Android intent (used when no documented deep link exists).
  final String? appLaunchPackage;

  /// Verified official website (opened WITHOUT claiming any prefill).
  final String? plainWebUrl;
  final String? playStoreUrl;
  final LocationFormat locationFormat;
  final String handoffNote;

  bool get supportsHandoff =>
      locationFormat == LocationFormat.latLng ||
      appDeepLinkBuilder != null;
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// Registry — easy to extend; every entry is verified (see class docs).
class BookingProviders {
  BookingProviders._();

  static const String _uberDocNote =
      'Uber opens with your pickup & drop prefilled (uber:// scheme + '
      'm.uber.com universal link — developer.uber.com).';
  static const String _olaDocNote =
      'Opens the Ola app directly (olacabs://app/launch — '
      'developers.olacabs.com). Ola\'s app scheme does not carry location '
      'parameters, so set the drop inside Ola (pickup = your GPS).';
  static const String _rapidoNote =
      'Opens the official Rapido app (Bike/Auto/Cab). Rapido has no public '
      'deep link, so pickup/drop are NOT prefilled — set them in Rapido.';

  // ---- Rides ----
  static const BookingProvider uber = BookingProvider(
    providerId: 'uber',
    providerName: 'Uber',
    category: BookingCategory.ride,
    emoji: '🚕',
    locationFormat: LocationFormat.latLng,
    appDeepLinkBuilder: _uberAppLink,
    webLinkBuilder: _uberLink,
    appLaunchPackage: 'com.ubercab',
    playStoreUrl:
        'https://play.google.com/store/apps/details?id=com.ubercab',
    appSchemePrefillsLocation: true,
    handoffNote: _uberDocNote,
  );

  /// Official native scheme (developer.uber.com, "Standard Deep Links":
  /// "the Uber rider app can be opened using the uber:// schema") — opens
  /// the installed app directly with the same setPickup parameters.
  static String _uberAppLink(BookingQuery q) =>
      _uberParams('uber://', q);

  static String _uberLink(BookingQuery q) {
    // Official universal link: https://m.uber.com/ul/?action=setPickup&…
    return _uberParams('https://m.uber.com/ul/', q);
  }

  static String _uberParams(String base, BookingQuery q) {
    final StringBuffer b = StringBuffer(base)
        ..write('?action=setPickup');
    if (q.hasFrom) {
      b.write('&pickup[latitude]=${q.fromLat!.toStringAsFixed(6)}'
          '&pickup[longitude]=${q.fromLng!.toStringAsFixed(6)}');
    } else {
      b.write('&pickup[latitude]=my_location'
          '&pickup[longitude]=my_location&pickup[nickname]=My%20location');
    }
    if (q.hasTo) {
      b.write('&dropoff[latitude]=${q.toLat!.toStringAsFixed(6)}'
          '&dropoff[longitude]=${q.toLng!.toStringAsFixed(6)}');
      if (q.toName != null && q.toName!.isNotEmpty) {
        b.write('&dropoff[nickname]=${Uri.encodeComponent(q.toName!)}');
      }
    }
    return b.toString();
  }

  static const BookingProvider ola = BookingProvider(
    providerId: 'ola',
    providerName: 'Ola',
    category: BookingCategory.ride,
    emoji: '🚙',
    locationFormat: LocationFormat.latLng,
    appDeepLinkBuilder: _olaAppLink,
    appLaunchPackage: 'com.olacabs',
    webLinkBuilder: _olaLink,
    playStoreUrl:
        'https://play.google.com/store/apps/details?id=com.olacabs',
    handoffNote: _olaDocNote,
  );

  /// Official app scheme (developers.olacabs.com): `olacabs://app/launch`
  /// "will open Ola App if it is present on the mobile device, else it will
  /// redirect the user to the Ola website". No location parameters are
  /// documented for the scheme — so none are invented here.
  static String _olaAppLink(BookingQuery q) => 'olacabs://app/launch';

  static String _olaLink(BookingQuery q) {
    // Official sample: book.olacabs.com/?lat=..&lng=..&drop_lat=..&drop_lng=..
    final StringBuffer b = StringBuffer('https://book.olacabs.com/');
    if (q.hasFrom) {
      b.write('?lat=${q.fromLat!.toStringAsFixed(6)}'
          '&lng=${q.fromLng!.toStringAsFixed(6)}');
      if (q.hasTo) {
        b.write('&drop_lat=${q.toLat!.toStringAsFixed(6)}'
            '&drop_lng=${q.toLng!.toStringAsFixed(6)}');
      }
    }
    return b.toString();
  }

  static const BookingProvider rapido = BookingProvider(
    providerId: 'rapido',
    providerName: 'Rapido',
    category: BookingCategory.ride,
    emoji: '🛵',
    locationFormat: LocationFormat.none,
    appLaunchPackage: 'com.rapido.passenger',
    playStoreUrl:
        'https://play.google.com/store/apps/details?id=com.rapido.passenger',
    handoffNote: _rapidoNote,
  );

  // ---- Trains (official India priority) ----
  static const BookingProvider irctc = BookingProvider(
    providerId: 'irctc',
    providerName: 'IRCTC (official)',
    category: BookingCategory.train,
    emoji: '🚆',
    locationFormat: LocationFormat.none,
    appLaunchPackage: 'cris.org.in.prs.ima',
    plainWebUrl: 'https://www.irctc.co.in/nget/train/search',
    playStoreUrl:
        'https://play.google.com/store/apps/details?id=cris.org.in.prs.ima',
    handoffNote:
        'Opens the official IRCTC Rail Connect app (or irctc.co.in). '
        'Route/date are NOT prefilled — IRCTC has no public deep link.',
  );

  // ---- Bus ----
  static const BookingProvider redbus = BookingProvider(
    providerId: 'redbus',
    providerName: 'redBus',
    category: BookingCategory.bus,
    emoji: '🚌',
    locationFormat: LocationFormat.none,
    plainWebUrl: 'https://www.redbus.in/',
    handoffNote:
        'Opens redbus.in — enter your route there. No public deep link is '
        'verified, so nothing is prefilled.',
  );

  // ---- Flights ----
  static const BookingProvider makemytripFlights = BookingProvider(
    providerId: 'makemytrip-flights',
    providerName: 'MakeMyTrip',
    category: BookingCategory.flight,
    emoji: '✈️',
    locationFormat: LocationFormat.none,
    appDeepLinkBuilder: _mmtFlightLink,
    handoffNote:
        'Opens MakeMyTrip\'s flight search with your route/date/pax filled '
        '(the site\'s own public search URL).',
  );

  static String _mmtFlightLink(BookingQuery q) {
    // Official public pattern: /flight/search?itinerary=DEL-BOM-13/09/2026
    //   &tripType=O&paxType=A-1_C-0_I-0&intl=false&cabinClass=E
    final String date = (q.date ?? '').replaceAll('-', '/');
    final String from = (q.fromName ?? '').trim().toUpperCase().isEmpty
        ? 'DEL'
        : q.fromName!.trim().toUpperCase();
    final String to = (q.toName ?? '').trim().toUpperCase().isEmpty
        ? 'BOM'
        : q.toName!.trim().toUpperCase();
    final String cls = switch ((q.travelClass ?? 'E').toUpperCase()) {
      'BUSINESS' || 'B' => 'B',
      'PREMIUM' || 'PE' => 'PE',
      _ => 'E',
    };
    return 'https://www.makemytrip.com/flight/search'
        '?itinerary=$from-$to-$date&tripType=${q.tripType}'
        '&paxType=A-${q.passengers}_C-0_I-0&intl=false&cabinClass=$cls';
  }

  static const BookingProvider goibiboFlights = BookingProvider(
    providerId: 'goibibo-flights',
    providerName: 'Goibibo',
    category: BookingCategory.flight,
    emoji: '🛫',
    locationFormat: LocationFormat.none,
    plainWebUrl: 'https://www.goibibo.com/flights/',
    handoffNote:
        'Opens Goibibo\'s official flights page — route entered there.',
  );

  // ---- Hotels ----
  static const BookingProvider bookingCom = BookingProvider(
    providerId: 'booking-com',
    providerName: 'Booking.com',
    category: BookingCategory.hotel,
    emoji: '🏨',
    locationFormat: LocationFormat.none,
    appDeepLinkBuilder: _bookingComLink,
    handoffNote:
        'Opens Booking.com search with destination/dates/guests filled '
        '(official searchresults.html parameters).',
  );

  static String _bookingComLink(BookingQuery q) {
    final StringBuffer b = StringBuffer(
        'https://www.booking.com/searchresults.html');
    final String dest = (q.toName ?? q.fromName ?? '').trim();
    if (dest.isNotEmpty) b.write('?ss=${Uri.encodeComponent(dest)}');
    final List<String> parts = <String>[];
    if (q.date != null) parts.add('checkin=${q.date}');
    if (q.returnDate != null) parts.add('checkout=${q.returnDate}');
    parts.add('group_adults=${q.passengers}');
    parts.add('no_rooms=${q.rooms}');
    b.write(b.toString().contains('?') ? '&' : '?');
    b.write(parts.join('&'));
    return b.toString();
  }

  // ---- Car rental ----
  static const BookingProvider zoomcar = BookingProvider(
    providerId: 'zoomcar',
    providerName: 'Zoomcar',
    category: BookingCategory.carRental,
    emoji: '🔑',
    locationFormat: LocationFormat.none,
    plainWebUrl: 'https://www.zoomcar.com/',
    handoffNote:
        'Opens zoomcar.com — choose your city/dates there. No verified '
        'query handoff, so nothing is prefilled.',
  );

  // ---- Activities ----
  static const BookingProvider headout = BookingProvider(
    providerId: 'headout',
    providerName: 'Headout',
    category: BookingCategory.activities,
    emoji: '🎭',
    locationFormat: LocationFormat.none,
    plainWebUrl: 'https://www.headout.com/',
    handoffNote: 'Opens headout.com — search experiences there.',
  );

  static const BookingProvider klook = BookingProvider(
    providerId: 'klook',
    providerName: 'Klook',
    category: BookingCategory.activities,
    emoji: '🎡',
    locationFormat: LocationFormat.none,
    plainWebUrl: 'https://www.klook.com/en-IN/',
    handoffNote: 'Opens klook.com — search activities there.',
  );

  static List<BookingProvider> forCategory(BookingCategory c) {
    switch (c) {
      case BookingCategory.ride:
        return const <BookingProvider>[uber, ola, rapido];
      case BookingCategory.flight:
        return const <BookingProvider>[makemytripFlights, goibiboFlights];
      case BookingCategory.train:
        return const <BookingProvider>[irctc];
      case BookingCategory.bus:
        return const <BookingProvider>[redbus];
      case BookingCategory.hotel:
        return const <BookingProvider>[bookingCom];
      case BookingCategory.carRental:
        return const <BookingProvider>[zoomcar];
      case BookingCategory.activities:
        return const <BookingProvider>[headout, klook];
    }
  }

  static String formatDmy(DateTime d) =>
      '${_twoDigits(d.day)}/${_twoDigits(d.month)}/${d.year}';

  static String formatIso(DateTime d) =>
      '${d.year}-${_twoDigits(d.month)}-${_twoDigits(d.day)}';
}

/// Future official-API integrations implement this — no UI changes needed.
abstract class BookingApi {
  /// True when the required partner credentials are configured.
  bool get isConfigured;
  Future<Object?> search(BookingQuery q);
  Future<Object?> book(BookingQuery q);
}
