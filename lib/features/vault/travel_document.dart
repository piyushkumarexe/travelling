// 🗂️ Travel Document & Booking Vault — data model.
//
// One document/booking entry. Metadata lives in Firestore at
// `users/{uid}/travelDocuments/{documentId}`; the actual PDF/image file
// lives in Firebase Storage at
// `users/{uid}/travelDocuments/{documentId}/file` and is referenced by
// [storagePath] + [fileUrl]. Only a `tripId` reference is stored for trip
// linking — trip data itself is never duplicated here.

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;


/// Document / booking types supported by the Vault.
enum TravelDocType {
  passport('Passport', '🛂'),
  visa('Visa', '🛂'),
  idProof('ID Proof', '🪪'),
  flightTicket('Flight Ticket', '✈️'),
  trainTicket('Train Ticket', '🚆'),
  busTicket('Bus Ticket', '🚌'),
  hotelBooking('Hotel Booking', '🏨'),
  cabRental('Cab / Car Rental', '🚗'),
  activityTicket('Activity / Event Ticket', '🎟️'),
  travelInsurance('Travel Insurance', '🛡️'),
  other('Other', '📄');

  const TravelDocType(this.label, this.emoji);
  final String label;
  final String emoji;

  static TravelDocType fromName(String name) => TravelDocType.values
      .where((TravelDocType t) => t.name == name)
      .firstOrNull ?? TravelDocType.other;
}

/// Upload lifecycle of the attached file. Firestore writes queue locally and
/// sync when back online; Storage uploads do NOT queue offline, so a failed
/// upload is surfaced honestly instead of pretending success.
enum VaultUploadStatus {
  none('No file'),
  uploaded('Uploaded'),
  uploadFailed('Upload failed');

  const VaultUploadStatus(this.label);
  final String label;

  static VaultUploadStatus fromName(String? name) => VaultUploadStatus.values
      .where((VaultUploadStatus s) => s.name == name)
      .firstOrNull ?? VaultUploadStatus.none;
}

/// Expiry state computed from the real current date — never stored.
enum VaultExpiryStatus {
  expired('Expired'),
  expiresToday('Expires today'),
  expiresSoon('Expires soon'),
  valid('Valid');

  const VaultExpiryStatus(this.label);
  final String label;
}

class TravelDocument {
  TravelDocument({
    required this.id,
    required this.userId,
    required this.type,
    required this.title,
    this.tripId,
    this.documentNumber,
    this.issuer,
    this.issueDate,
    this.expiryDate,
    this.travelDate,
    this.startDate,
    this.endDate,
    this.departureLocation,
    this.arrivalLocation,
    this.notes,
    this.fileUrl,
    this.storagePath,
    this.fileName,
    this.fileSize,
    this.uploadStatus = VaultUploadStatus.none,
    // ---- booking-specific optional fields (all editable) ----
    this.pnr,
    this.bookingRef,
    this.airline,
    this.flightNumber,
    this.departureAirport,
    this.arrivalAirport,
    this.terminal,
    this.seat,
    this.departureDateTime,
    this.arrivalDateTime,
    this.hotelName,
    this.checkInDateTime,
    this.checkOutDateTime,
    this.address,
    this.contact,
    this.operatorName,
    this.providerName,
    this.venue,
    this.location,
    this.eventDateTime,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String userId;
  final String? tripId;
  final TravelDocType type;
  final String title;

  // Generic fields.
  final String? documentNumber; // document number / booking id / PNR
  final String? issuer; // issuing authority / provider / hotel / airline
  final DateTime? issueDate;
  final DateTime? expiryDate;
  final DateTime? travelDate;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? departureLocation;
  final String? arrivalLocation;
  final String? notes;

  // Attached file (Storage).
  final String? fileUrl;
  final String? storagePath;
  final String? fileName;
  final int? fileSize;
  final VaultUploadStatus uploadStatus;

  // Booking-specific optional fields.
  final String? pnr;
  final String? bookingRef;
  final String? airline;
  final String? flightNumber;
  final String? departureAirport;
  final String? arrivalAirport;
  final String? terminal;
  final String? seat; // seat / coach
  final DateTime? departureDateTime;
  final DateTime? arrivalDateTime;
  final String? hotelName;
  final DateTime? checkInDateTime;
  final DateTime? checkOutDateTime;
  final String? address;
  final String? contact;
  final String? operatorName;
  final String? providerName;
  final String? venue;
  final String? location;
  final DateTime? eventDateTime;

  final DateTime createdAt;
  final DateTime updatedAt;

  TravelDocType get docType => type;

  // ---------------- expiry ----------------

  static const int expiringSoonDays = 30;

  /// Expiry state computed against the real current date (date precision).
  VaultExpiryStatus expiryStatus([DateTime? now]) {
    final DateTime? e = expiryDate;
    if (e == null) return VaultExpiryStatus.valid;
    final DateTime today = _dateOnly(now ?? DateTime.now());
    final DateTime exp = _dateOnly(e);
    final int days = exp.difference(today).inDays;
    if (days < 0) return VaultExpiryStatus.expired;
    if (days == 0) return VaultExpiryStatus.expiresToday;
    if (days <= expiringSoonDays) return VaultExpiryStatus.expiresSoon;
    return VaultExpiryStatus.valid;
  }

  /// Days until expiry (negative = already expired).
  int daysUntilExpiry([DateTime? now]) =>
      _dateOnly(expiryDate!).difference(_dateOnly(now ?? DateTime.now())).inDays;

  // ---------------- timeline ----------------

  /// The real saved date this entry contributes to the upcoming timeline,
  /// or null when this entry has no usable date.
  DateTime? get timelineDate => _firstDate(<DateTime?>[
        departureDateTime,
        checkInDateTime,
        eventDateTime,
        startDate,
        travelDate,
      ]);

  /// Short human label built ONLY from real saved data.
  String timelineLabel() => switch (type) {
        TravelDocType.flightTicket =>
          'Flight ${_route(airline ?? flightNumber, departureAirport ?? departureLocation, arrivalAirport ?? arrivalLocation)}',
        TravelDocType.hotelBooking =>
          'Hotel check-in ${hotelName ?? issuer ?? title}'.trim(),
        TravelDocType.trainTicket =>
          'Train ${_route(operatorName ?? issuer, departureLocation, arrivalLocation)}',
        TravelDocType.busTicket =>
          'Bus ${_route(operatorName ?? issuer, departureLocation, arrivalLocation)}',
        TravelDocType.activityTicket =>
          'Activity ${providerName ?? venue ?? title}'.trim(),
        TravelDocType.cabRental =>
          'Cab pickup ${operatorName ?? issuer ?? title}'.trim(),
        _ => title,
      };

  /// End-of-stay dates also join the timeline (e.g. hotel check-out,
  /// return flight arrival).
  List<(DateTime, String)> timelineEntries() {
    final List<(DateTime, String)> out = <(DateTime, String)>[];
    final DateTime? start = timelineDate;
    if (start != null) out.add((start, timelineLabel()));
    final DateTime? end = _firstDate(<DateTime?>[
      if (type == TravelDocType.flightTicket) arrivalDateTime,
      if (type == TravelDocType.hotelBooking) checkOutDateTime,
      if (type == TravelDocType.trainTicket) arrivalDateTime,
      if (type == TravelDocType.busTicket) arrivalDateTime,
      endDate,
    ]);
    if (end != null && (start == null || !end.isAtSameMomentAs(start))) {
      out.add((end, switch (type) {
        TravelDocType.flightTicket => 'Arrival $title',
        TravelDocType.hotelBooking => 'Check-out ${hotelName ?? title}',
        _ => 'End — $title',
      }));
    }
    return out;
  }

  // ---------------- search ----------------

  /// Case-insensitive match over title, numbers, providers and trip name —
  /// the fields a traveller searches by.
  bool matchesQuery(String rawQuery, String? tripName) {
    final String q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    final List<String> haystacks = <String>[
      title,
      documentNumber ?? '',
      pnr ?? '',
      bookingRef ?? '',
      airline ?? '',
      flightNumber ?? '',
      hotelName ?? '',
      operatorName ?? '',
      providerName ?? '',
      issuer ?? '',
      departureLocation ?? '',
      arrivalLocation ?? '',
      departureAirport ?? '',
      arrivalAirport ?? '',
      tripName ?? '',
    ];
    return haystacks.any((String h) => h.toLowerCase().contains(q));
  }

  // ---------------- copy / firestore ----------------

  TravelDocument copyWith({
    String? tripId,
    bool clearTrip = false,
    String? fileUrl,
    String? storagePath,
    String? fileName,
    int? fileSize,
    VaultUploadStatus? uploadStatus,
    DateTime? updatedAt,
  }) {
    return TravelDocument(
      id: id,
      userId: userId,
      tripId: clearTrip ? null : (tripId ?? this.tripId),
      type: type,
      title: title,
      documentNumber: documentNumber,
      issuer: issuer,
      issueDate: issueDate,
      expiryDate: expiryDate,
      travelDate: travelDate,
      startDate: startDate,
      endDate: endDate,
      departureLocation: departureLocation,
      arrivalLocation: arrivalLocation,
      notes: notes,
      fileUrl: fileUrl ?? this.fileUrl,
      storagePath: storagePath ?? this.storagePath,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      pnr: pnr,
      bookingRef: bookingRef,
      airline: airline,
      flightNumber: flightNumber,
      departureAirport: departureAirport,
      arrivalAirport: arrivalAirport,
      terminal: terminal,
      seat: seat,
      departureDateTime: departureDateTime,
      arrivalDateTime: arrivalDateTime,
      hotelName: hotelName,
      checkInDateTime: checkInDateTime,
      checkOutDateTime: checkOutDateTime,
      address: address,
      contact: contact,
      operatorName: operatorName,
      providerName: providerName,
      venue: venue,
      location: location,
      eventDateTime: eventDateTime,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Firestore mapping uses millisecond epochs (same convention as
  /// bookingRefs / expenses). Sensitive values are never transformed or
  /// logged here.
  Map<String, dynamic> toFirestore() => <String, dynamic>{
        'documentId': id,
        'userId': userId,
        'tripId': tripId,
        'type': type.name,
        'title': title,
        'documentNumber': documentNumber,
        'issuer': issuer,
        'issueDate': _ms(issueDate),
        'expiryDate': _ms(expiryDate),
        'travelDate': _ms(travelDate),
        'startDate': _ms(startDate),
        'endDate': _ms(endDate),
        'departureLocation': departureLocation,
        'arrivalLocation': arrivalLocation,
        'notes': notes,
        'fileUrl': fileUrl,
        'storagePath': storagePath,
        'fileName': fileName,
        'fileSize': fileSize,
        'uploadStatus': uploadStatus.name,
        'pnr': pnr,
        'bookingRef': bookingRef,
        'airline': airline,
        'flightNumber': flightNumber,
        'departureAirport': departureAirport,
        'arrivalAirport': arrivalAirport,
        'terminal': terminal,
        'seat': seat,
        'departureDateTime': _ms(departureDateTime),
        'arrivalDateTime': _ms(arrivalDateTime),
        'hotelName': hotelName,
        'checkInDateTime': _ms(checkInDateTime),
        'checkOutDateTime': _ms(checkOutDateTime),
        'address': address,
        'contact': contact,
        'operatorName': operatorName,
        'providerName': providerName,
        'venue': venue,
        'location': location,
        'eventDateTime': _ms(eventDateTime),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static TravelDocument fromFirestore(String id, Map<String, dynamic> m) {
    DateTime? ms(Object? v) => v is int
        ? DateTime.fromMillisecondsSinceEpoch(v)
        : (v is Timestamp ? v.toDate() : null);
    return TravelDocument(
      id: (m['documentId'] as String?) ?? id,
      userId: (m['userId'] as String?) ?? '',
      tripId: m['tripId'] as String?,
      type: TravelDocType.fromName((m['type'] as String?) ?? 'other'),
      title: (m['title'] as String?) ?? '',
      documentNumber: m['documentNumber'] as String?,
      issuer: m['issuer'] as String?,
      issueDate: ms(m['issueDate']),
      expiryDate: ms(m['expiryDate']),
      travelDate: ms(m['travelDate']),
      startDate: ms(m['startDate']),
      endDate: ms(m['endDate']),
      departureLocation: m['departureLocation'] as String?,
      arrivalLocation: m['arrivalLocation'] as String?,
      notes: m['notes'] as String?,
      fileUrl: m['fileUrl'] as String?,
      storagePath: m['storagePath'] as String?,
      fileName: m['fileName'] as String?,
      fileSize: m['fileSize'] as int?,
      uploadStatus:
          VaultUploadStatus.fromName(m['uploadStatus'] as String?),
      pnr: m['pnr'] as String?,
      bookingRef: m['bookingRef'] as String?,
      airline: m['airline'] as String?,
      flightNumber: m['flightNumber'] as String?,
      departureAirport: m['departureAirport'] as String?,
      arrivalAirport: m['arrivalAirport'] as String?,
      terminal: m['terminal'] as String?,
      seat: m['seat'] as String?,
      departureDateTime: ms(m['departureDateTime']),
      arrivalDateTime: ms(m['arrivalDateTime']),
      hotelName: m['hotelName'] as String?,
      checkInDateTime: ms(m['checkInDateTime']),
      checkOutDateTime: ms(m['checkOutDateTime']),
      address: m['address'] as String?,
      contact: m['contact'] as String?,
      operatorName: m['operatorName'] as String?,
      providerName: m['providerName'] as String?,
      venue: m['venue'] as String?,
      location: m['location'] as String?,
      eventDateTime: ms(m['eventDateTime']),
      createdAt: ms(m['createdAt']) ?? DateTime.now(),
      updatedAt: ms(m['updatedAt']) ?? DateTime.now(),
    );
  }

  // ---------------- helpers ----------------

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime? _firstDate(List<DateTime?> candidates) {
    for (final DateTime? c in candidates) {
      if (c != null) return c;
    }
    return null;
  }

  static int? _ms(DateTime? d) => d?.millisecondsSinceEpoch;

  static String _route(String? who, String? from, String? to) {
    final String route = (from != null && from.isNotEmpty && to != null && to.isNotEmpty)
        ? '$from → $to'
        : (to ?? from ?? '');
    return who == null || who.isEmpty
        ? route
        : (route.isEmpty ? who : '$who $route');
  }
}

/// Deterministic reminder offsets (days before expiry), per spec.
const List<int> kVaultReminderOffsets = <int>[90, 30, 7, 1];

/// Reminder local wall-clock hour.
const int kVaultReminderHour = 9;

/// Reminder datetimes for a document: expiry-90d / -30d / -7d / -1d at
/// 09:00 device-local time — only those still in the future, and only for
/// documents that actually have an expiry date.
List<DateTime> vaultReminderTimes(DateTime expiryDate, DateTime now) {
  final DateTime nineAm = DateTime(
      expiryDate.year, expiryDate.month, expiryDate.day, kVaultReminderHour);
  return <DateTime>[
    for (final int offset in kVaultReminderOffsets)
      nineAm.subtract(Duration(days: offset)),
  ].where((DateTime t) => t.isAfter(now)).toList();
}

/// Stable notification id for (document, offset) — deterministic across
/// app restarts so reminders can be cancelled/replaced reliably.
int vaultReminderId(String documentId, int offsetDays) {
  // FNV-1a 32-bit — stable, unlike String.hashCode.
  int h = 0x811c9dc5;
  for (final int code in documentId.codeUnits) {
    h ^= code;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return ((h + offsetDays) & 0x7FFFFFFF);
}
