import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/local/trip_plan_store.dart';
import 'booking_models.dart';

/// A saved booking reference (user-entered after an external booking —
/// NEVER auto-marked confirmed; only metadata is stored).
@immutable
class BookingRef {
  const BookingRef({
    required this.id,
    required this.userId,
    required this.category,
    required this.provider,
    required this.serviceType,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.tripId,
    this.origin,
    this.destination,
    this.bookingDate,
    this.externalReference,
    this.notes,
  });

  final String id;
  final String userId;
  final String category; // BookingCategory name
  final String provider;
  final String serviceType; // bike/auto/cab/economy/…
  final String status; // saved | confirmed | cancelled (user-set)
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? tripId;
  final String? origin;
  final String? destination;
  final String? bookingDate; // yyyy-MM-dd
  final String? externalReference; // PNR / booking id the user enters
  final String? notes;

  Map<String, dynamic> toFirestore() => <String, dynamic>{
        'bookingId': id,
        'userId': userId,
        'tripId': tripId,
        'category': category,
        'provider': provider,
        'serviceType': serviceType,
        'origin': origin,
        'destination': destination,
        'bookingDate': bookingDate,
        'status': status,
        'externalReference': externalReference,
        'notes': notes,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static BookingRef fromFirestore(Map<String, dynamic> m) => BookingRef(
        id: (m['bookingId'] as String?) ?? '',
        userId: (m['userId'] as String?) ?? '',
        category: (m['category'] as String?) ?? 'ride',
        provider: (m['provider'] as String?) ?? '',
        serviceType: (m['serviceType'] as String?) ?? '',
        status: (m['status'] as String?) ?? 'saved',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            ((m['createdAt'] as num?) ?? 0).toInt()),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            ((m['updatedAt'] as num?) ?? 0).toInt()),
        tripId: m['tripId'] as String?,
        origin: m['origin'] as String?,
        destination: m['destination'] as String?,
        bookingDate: m['bookingDate'] as String?,
        externalReference: m['externalReference'] as String?,
        notes: m['notes'] as String?,
      );
}

/// 🧳 Booking hand-off + history service.
///
/// - Launches VERIFIED official provider flows only (app/universal link →
///   official web → Play Store). No canLaunchUrl probing, no scraping.
/// - Keeps recent locations locally (max 8, clearable).
/// - Saves user-entered booking references to Firestore
///   users/{uid}/bookingRefs (owner-only rules) with a local mirror.
class BookingService extends ChangeNotifier {
  final TripPlanStore tripStore;

  BookingService({required this.tripStore});

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  String? _uid;
  List<BookingRef> _bookings = const <BookingRef>[];
  bool _loading = false;
  String? _lastError;

  List<BookingRef> get bookings => _bookings;
  bool get loading => _loading;
  String? get lastError => _lastError;

  // ---------------- recent locations ----------------
  static const String _recentKey = 'booking.recent.locations.v1';

  Future<List<({String name, double lat, double lng})>> recentLocations() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> raw = prefs.getStringList(_recentKey) ??
          const <String>[];
      return raw.map((String e) {
        final List<String> p = e.split('|');
        return (
          name: p[0],
          lat: double.parse(p[1]),
          lng: double.parse(p[2]),
        );
      }).toList();
    } catch (_) {
      return const <({String name, double lat, double lng})>[];
    }
  }

  Future<void> addRecentLocation(String name, double lat, double lng) async {
    if (name.trim().isEmpty) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> raw = prefs.getStringList(_recentKey) ?? <String>[];
      final String entry = '$name|$lat|$lng';
      raw
        ..removeWhere((String e) => e.split('|').first == name.trim())
        ..insert(0, entry);
      if (raw.length > 8) raw.removeRange(8, raw.length);
      await prefs.setStringList(_recentKey, raw);
    } catch (_) {}
  }

  Future<void> clearRecentLocations() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentKey);
    notifyListeners();
  }

  // ---------------- launching ----------------

  /// Result states for honest UI handling.
  BookingLaunchResult _lastLaunchResult = BookingLaunchResult.ok;
  BookingLaunchResult get lastLaunchResult => _lastLaunchResult;

  /// Opens the provider's official flow: documented deep/universal link or
  /// direct app launch first, then the official website, then the Play
  /// Store listing. Reports exactly what happened.
  Future<BookingLaunchResult> continueWithProvider(
      BookingProvider provider, BookingQuery q) async {
    _lastLaunchResult = BookingLaunchResult.ok;
    // 1) Verified deep/universal link (also covers mobile-web fallback).
    if (provider.appDeepLinkBuilder != null) {
      final String link = provider.appDeepLinkBuilder!(q);
      final bool ok = await _launch(link);
      if (ok) return BookingLaunchResult.opened;
      // Universal link failed entirely (offline / resolver error).
      _lastLaunchResult = BookingLaunchResult.linkInvalid;
    }
    // 2) Direct official app launch (package verified).
    if (provider.appLaunchPackage != null) {
      final String intent = 'intent://launch/#Intent;'
          'action=android.intent.action.MAIN;'
          'category=android.intent.category.LAUNCHER;'
          'package=${provider.appLaunchPackage};end';
      final bool ok = await _launch(intent);
      if (ok) return BookingLaunchResult.openedApp;
    }
    // 3) Verified https link with prefill — opens the provider's mobile web
    //    flow (or their app, when the OS hands the universal link over).
    if (provider.webLinkBuilder != null) {
      final String link = provider.webLinkBuilder!(q);
      final bool ok = await _launch(link);
      if (ok) return BookingLaunchResult.openedWeb;
    }
    // 4) Play Store fallback (official listing).
    if (provider.playStoreUrl != null &&
        await _launch(provider.playStoreUrl!)) {
      return BookingLaunchResult.appNotInstalled;
    }
    // 5) Official website without prefill.
    if (provider.plainWebUrl != null) {
      final bool ok = await _launch(provider.plainWebUrl!);
      if (ok) return BookingLaunchResult.openedWeb;
      _lastLaunchResult = BookingLaunchResult.networkError;
      return _lastLaunchResult;
    }
    _lastLaunchResult = BookingLaunchResult.linkInvalid;
    return _lastLaunchResult;
  }

  Future<bool> _launch(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      // ActivityNotFoundException etc (app missing / nothing handles it).
      return false;
    } catch (_) {
      return false;
    }
  }

  // ---------------- saved booking references ----------------

  String newBookingId() =>
      'bk-${DateTime.now().millisecondsSinceEpoch}'
      '-${DateTime.now().microsecondsSinceEpoch % 100000}';

  Future<void> start(String uid) async {
    if (_uid == uid) return;
    _uid = uid;
    _loadRemote();
    notifyListeners();
  }

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('users').doc(_uid!).collection('bookingRefs');

  void _loadRemote() {
    _loading = true;
    notifyListeners();
    _col.orderBy('createdAt', descending: true).limit(50).snapshots().listen(
      (QuerySnapshot<Map<String, dynamic>> snap) {
        _bookings = snap.docs
            .map((QueryDocumentSnapshot<Map<String, dynamic>> d) =>
                BookingRef.fromFirestore(d.data()))
            .toList();
        _loading = false;
        notifyListeners();
      },
      onError: (Object e) {
        _lastError = 'Saved bookings unavailable offline.';
        _loading = false;
        notifyListeners();
      },
    );
  }

  /// Manual save AFTER an external booking (user enters the reference).
  Future<bool> saveBooking(BookingRef ref) async {
    if (_uid == null) return false;
    try {
      await _col.doc(ref.id).set(ref.toFirestore());
      return true;
    } on FirebaseException catch (e) {
      _lastError = 'Could not save: ${e.code}. Check your internet and retry.';
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteBooking(String id) async {
    if (_uid == null) return false;
    try {
      await _col.doc(id).delete();
      return true;
    } on FirebaseException {
      return false;
    }
  }

  /// Trip name via the existing local trip store (no duplication).
  String tripName(String? tripId) {
    if (tripId == null) return '';
    for (final trip in tripStore.plans) {
      if (trip.id == tripId) return trip.destination;
    }
    return '';
  }
}

enum BookingLaunchResult {
  ok, // initial/reset state
  opened, // universal/deep link fired (app or provider web)
  openedApp, // official app launched directly
  openedWeb, // official website opened (no prefill)
  appNotInstalled, // official app missing → Play listing shown
  linkInvalid, // link could not be handled
  networkError,
}

String describeLaunch(BookingLaunchResult r) => switch (r) {
      BookingLaunchResult.ok => '',
      BookingLaunchResult.opened =>
        'Continued with the provider\'s official booking flow.',
      BookingLaunchResult.openedApp => 'Official provider app opened.',
      BookingLaunchResult.openedWeb =>
        'Official website opened (no location prefill).',
      BookingLaunchResult.appNotInstalled =>
        'The provider app is not installed — its official Play Store page '
            'was opened.',
      BookingLaunchResult.linkInvalid =>
        'This link could not be opened on your device.',
      BookingLaunchResult.networkError =>
        'No internet connection. Check your network and retry.',
    };

/// JSON helper kept local to avoid extra imports in callers.
String encodeBookingRef(BookingRef r) => jsonEncode(r.toFirestore());
