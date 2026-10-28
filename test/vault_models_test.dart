import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/features/vault/travel_document.dart';

TravelDocument _doc(Map<String, Object?> overrides) {
  final Map<String, Object?> m = <String, Object?>{
    'id': 'doc1',
    'userId': 'user1',
    'type': TravelDocType.flightTicket,
    'title': 'Flight to Dubai',
    'createdAt': DateTime(2026, 9, 1),
    'updatedAt': DateTime(2026, 9, 2),
  }..addAll(overrides);
  return TravelDocument(
    id: m['id']! as String,
    userId: m['userId']! as String,
    type: m['type']! as TravelDocType,
    title: m['title']! as String,
    tripId: m['tripId'] as String?,
    documentNumber: m['documentNumber'] as String?,
    issuer: m['issuer'] as String?,
    issueDate: m['issueDate'] as DateTime?,
    expiryDate: m['expiryDate'] as DateTime?,
    travelDate: m['travelDate'] as DateTime?,
    startDate: m['startDate'] as DateTime?,
    endDate: m['endDate'] as DateTime?,
    departureLocation: m['departureLocation'] as String?,
    arrivalLocation: m['arrivalLocation'] as String?,
    notes: m['notes'] as String?,
    fileUrl: m['fileUrl'] as String?,
    storagePath: m['storagePath'] as String?,
    fileName: m['fileName'] as String?,
    fileSize: m['fileSize'] as int?,
    uploadStatus: (m['uploadStatus'] as VaultUploadStatus?) ??
        VaultUploadStatus.none,
    pnr: m['pnr'] as String?,
    bookingRef: m['bookingRef'] as String?,
    airline: m['airline'] as String?,
    flightNumber: m['flightNumber'] as String?,
    departureAirport: m['departureAirport'] as String?,
    arrivalAirport: m['arrivalAirport'] as String?,
    terminal: m['terminal'] as String?,
    seat: m['seat'] as String?,
    departureDateTime: m['departureDateTime'] as DateTime?,
    arrivalDateTime: m['arrivalDateTime'] as DateTime?,
    hotelName: m['hotelName'] as String?,
    checkInDateTime: m['checkInDateTime'] as DateTime?,
    checkOutDateTime: m['checkOutDateTime'] as DateTime?,
    address: m['address'] as String?,
    contact: m['contact'] as String?,
    operatorName: m['operatorName'] as String?,
    providerName: m['providerName'] as String?,
    venue: m['venue'] as String?,
    location: m['location'] as String?,
    eventDateTime: m['eventDateTime'] as DateTime?,
    createdAt: m['createdAt']! as DateTime,
    updatedAt: m['updatedAt']! as DateTime,
  );
}

void main() {
  group('TravelDocument ⇄ Firestore roundtrip', () {
    test('preserves every field through toFirestore/fromFirestore', () {
      final TravelDocument d = _doc(<String, Object?>{
        'tripId': 'trip-42',
        'documentNumber': 'J8345567',
        'issuer': 'Emirates',
        'issueDate': DateTime(2026, 1, 15),
        'expiryDate': DateTime(2031, 1, 15, 9),
        'travelDate': DateTime(2026, 9, 20),
        'departureLocation': 'Delhi',
        'arrivalLocation': 'Dubai',
        'notes': 'Window seat preferred',
        'fileUrl': 'https://files.example/file.jpg',
        'storagePath': 'users/user1/travelDocuments/doc1/file',
        'fileName': 'ticket.pdf',
        'fileSize': 123456,
        'uploadStatus': VaultUploadStatus.uploaded,
        'pnr': 'PNR123',
        'bookingRef': 'BR-99',
        'airline': 'Emirates',
        'flightNumber': 'EK-515',
        'departureAirport': 'DEL',
        'arrivalAirport': 'DXB',
        'terminal': '3',
        'seat': '21A',
        'departureDateTime': DateTime(2026, 9, 20, 10, 30),
        'arrivalDateTime': DateTime(2026, 9, 20, 13, 5),
        'hotelName': 'Grand Hotel',
        'checkInDateTime': DateTime(2026, 9, 20, 14),
        'checkOutDateTime': DateTime(2026, 9, 25, 11),
        'address': 'Beach Rd 1',
        'contact': '+91 90000 00000',
        'operatorName': 'IndiGo',
        'providerName': 'Headout',
        'venue': 'Burj Hall',
        'location': 'Downtown',
        'eventDateTime': DateTime(2026, 9, 22, 19),
      });
      final TravelDocument r =
          TravelDocument.fromFirestore(d.id, d.toFirestore());
      expect(r.id, d.id);
      expect(r.userId, d.userId);
      expect(r.tripId, 'trip-42');
      expect(r.type, TravelDocType.flightTicket);
      expect(r.title, d.title);
      expect(r.documentNumber, 'J8345567');
      expect(r.issuer, 'Emirates');
      expect(r.issueDate, d.issueDate);
      expect(r.expiryDate, d.expiryDate);
      expect(r.travelDate, d.travelDate);
      expect(r.startDate, isNull);
      expect(r.departureLocation, 'Delhi');
      expect(r.arrivalLocation, 'Dubai');
      expect(r.notes, 'Window seat preferred');
      expect(r.fileUrl, d.fileUrl);
      expect(r.storagePath, d.storagePath);
      expect(r.fileName, 'ticket.pdf');
      expect(r.fileSize, 123456);
      expect(r.uploadStatus, VaultUploadStatus.uploaded);
      expect(r.pnr, 'PNR123');
      expect(r.bookingRef, 'BR-99');
      expect(r.airline, 'Emirates');
      expect(r.flightNumber, 'EK-515');
      expect(r.departureAirport, 'DEL');
      expect(r.arrivalAirport, 'DXB');
      expect(r.terminal, '3');
      expect(r.seat, '21A');
      expect(r.departureDateTime, d.departureDateTime);
      expect(r.arrivalDateTime, d.arrivalDateTime);
      expect(r.hotelName, 'Grand Hotel');
      expect(r.checkInDateTime, d.checkInDateTime);
      expect(r.checkOutDateTime, d.checkOutDateTime);
      expect(r.address, 'Beach Rd 1');
      expect(r.contact, '+91 90000 00000');
      expect(r.operatorName, 'IndiGo');
      expect(r.providerName, 'Headout');
      expect(r.venue, 'Burj Hall');
      expect(r.location, 'Downtown');
      expect(r.eventDateTime, d.eventDateTime);
      expect(r.createdAt, d.createdAt);
      expect(r.updatedAt, d.updatedAt);
    });
  });

  group('Expiry status (computed from the real current date)', () {
    final DateTime now = DateTime(2026, 9, 14, 12);
    test('expired / today / soon / valid', () {
      expect(
          _doc(<String, Object?>{
            'expiryDate': DateTime(2026, 9, 10),
          }).expiryStatus(now),
          VaultExpiryStatus.expired);
      expect(
          _doc(<String, Object?>{
            'expiryDate': DateTime(2026, 9, 14, 23, 59),
          }).expiryStatus(now),
          VaultExpiryStatus.expiresToday);
      expect(
          _doc(<String, Object?>{
            'expiryDate': DateTime(2026, 10, 5),
          }).expiryStatus(now),
          VaultExpiryStatus.expiresSoon);
      expect(
          _doc(<String, Object?>{
            'expiryDate': DateTime(2027, 3, 1),
          }).expiryStatus(now),
          VaultExpiryStatus.valid);
    });
    test('daysUntilExpiry is date-accurate', () {
      final TravelDocument d = _doc(<String, Object?>{
        'expiryDate': DateTime(2026, 9, 20),
      });
      expect(d.daysUntilExpiry(now), 6);
    });
    test('no expiry date → valid and never "expiring"', () {
      final TravelDocument d = _doc(<String, Object?>{});
      expect(d.expiryStatus(now), VaultExpiryStatus.valid);
      expect(d.expiryDate, isNull);
    });
  });

  group('Upcoming timeline (real saved dates only)', () {
    final DateTime now = DateTime(2026, 9, 14, 12);
    test('builds sorted entries from departures and check-ins, skips past',
        () {
      final TravelDocument flight = _doc(<String, Object?>{
        'title': 'Delhi → Dubai flight',
        'departureDateTime': DateTime(2026, 9, 15, 10, 30),
        'arrivalDateTime': DateTime(2026, 9, 15, 13, 5),
        'departureAirport': 'Delhi',
        'arrivalAirport': 'Dubai',
        'airline': 'Emirates',
      });
      final TravelDocument hotel = _doc(<String, Object?>{
        'type': TravelDocType.hotelBooking,
        'title': 'Grand Hotel',
        'hotelName': 'Grand Hotel',
        'checkInDateTime': DateTime(2026, 9, 16, 14),
        'checkOutDateTime': DateTime(2026, 9, 20, 11),
      });
      final TravelDocument past = _doc(<String, Object?>{
        'title': 'old trip',
        'departureDateTime': DateTime(2026, 9, 1, 8),
      });
      final List<(DateTime, String)> all = <(DateTime, String)>[
        ...flight.timelineEntries(),
        ...hotel.timelineEntries(),
        ...past.timelineEntries(),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      final List<(DateTime, String)> upcoming = all
          .where(((DateTime, String) e) =>
              !e.$1.isBefore(DateTime(now.year, now.month, now.day)))
          .toList();
      expect(upcoming.length, 4); // flight dep+arr, hotel in+out
      expect(upcoming[0].$1, DateTime(2026, 9, 15, 10, 30));
      expect(upcoming[0].$2, contains('Delhi → Dubai'));
      expect(upcoming[0].$2, contains('Emirates'));
      expect(upcoming[1].$2, 'Arrival Delhi → Dubai flight');
      expect(upcoming[2].$2, contains('Grand Hotel'));
      expect(upcoming[3].$2, contains('Check-out'));
      // Past entries exist but are excluded from the timeline.
      expect(past.timelineEntries(), isNotEmpty);
    });
    test('documents without any date contribute no entries', () {
      expect(_doc(<String, Object?>{}).timelineEntries(), isEmpty);
    });
  });

  group('Expiry reminders', () {
    final DateTime expiry = DateTime(2026, 12, 20);
    final DateTime now = DateTime(2026, 9, 14, 12);
    test('schedules 90/30/7/1-day reminders at 09:00, future only', () {
      final List<DateTime> times = vaultReminderTimes(expiry, now);
      expect(times.length, 4);
      expect(times[0], DateTime(2026, 12, 20, 9).subtract(const Duration(days: 90)));
      expect(times[1], DateTime(2026, 12, 20, 9).subtract(const Duration(days: 30)));
      expect(times[2], DateTime(2026, 12, 20, 9).subtract(const Duration(days: 7)));
      expect(times[3], DateTime(2026, 12, 20, 9).subtract(const Duration(days: 1)));
    });
    test('excludes offsets already in the past', () {
      // Expiry in 20 days → only the 7- and 1-day reminders remain.
      final DateTime soon = now.add(const Duration(days: 20));
      final List<DateTime> times = vaultReminderTimes(soon, now);
      expect(times.length, 2);
      expect(
          times[0], DateTime(soon.year, soon.month, soon.day, 9)
              .subtract(const Duration(days: 7)));
      expect(
          times[1], DateTime(soon.year, soon.month, soon.day, 9)
              .subtract(const Duration(days: 1)));
    });
    test('ids are deterministic per (document, offset)', () {
      expect(vaultReminderId('abc', 7), vaultReminderId('abc', 7));
      expect(vaultReminderId('abc', 7), isNot(vaultReminderId('abc', 1)));
      expect(vaultReminderId('abc', 7), isNot(vaultReminderId('xyz', 7)));
      expect(vaultReminderId('abc', 90), inInclusiveRange(0, 0x7FFFFFFF));
    });
  });

  group('Search', () {
    final TravelDocument flight = _doc(<String, Object?>{
      'title': 'Delhi → Dubai',
      'pnr': 'PNR123',
      'airline': 'Emirates',
      'tripId': 't1',
    });
    test('matches title / PNR / airline / trip name case-insensitively', () {
      expect(flight.matchesQuery('pnr1', 'Goa trip'), isTrue);
      expect(flight.matchesQuery('EMIR', 'Goa trip'), isTrue);
      expect(flight.matchesQuery('delhi', 'Goa trip'), isTrue);
      expect(flight.matchesQuery('goa', 'Goa trip'), isTrue);
      expect(flight.matchesQuery('mumbai', 'Goa trip'), isFalse);
    });
  });
}
