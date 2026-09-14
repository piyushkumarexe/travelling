// 🗂️ Travel Document & Booking Vault — service.
//
// Firestore metadata: users/{uid}/travelDocuments/{documentId}
// Storage file:      users/{uid}/travelDocuments/{documentId}/file
// (owner-only, enforced by firestore.rules + storage.rules).
//
// Reuses the app's existing StorageService (validation + upload) and
// NotificationService (expiry reminders) — no duplicate systems. This class
// never logs document contents, numbers, PNRs or file URLs.

import 'dart:async' show StreamSubscription, unawaited;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart' show Task;
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart' show XFile;

import '../../core/services/notification_service.dart';
import '../../core/services/storage_service.dart';
import '../../data/local/trip_plan_store.dart';
import 'travel_document.dart';

class VaultService extends ChangeNotifier {
  VaultService({
    required StorageService storage,
    required NotificationService notifications,
    required TripPlanStore trips,
  })  : _storage = storage,
        _notifications = notifications,
        _trips = trips;

  final StorageService _storage;
  final NotificationService _notifications;
  final TripPlanStore _trips;

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  String? _uid;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  List<TravelDocument> _docs = const <TravelDocument>[];
  bool _loading = false;
  String? _lastError;
  bool _remindersPermission = true;

  List<TravelDocument> get docs => _docs;
  bool get loading => _loading;
  String? get lastError => _lastError;

  /// Whether OS notification permission was granted the last time it was
  /// checked — surfaced honestly in the UI when false.
  bool get remindersPermission => _remindersPermission;

  /// Pending reminder notification ids from the last refresh, so a later
  /// refresh can replace them without duplicates.
  final Set<int> _scheduledIds = <int>{};

  // ---------------- listening ----------------

  /// Starts (or restarts) the owner-scoped metadata stream and refreshes
  /// expiry reminders. Metadata-only — no files are downloaded here.
  void start(String uid) {
    if (_uid == uid && _sub != null) return;
    _uid = uid;
    _loading = true;
    notifyListeners();
    _sub = _db
        .collection('users')
        .doc(uid)
        .collection('travelDocuments')
        .limit(200)
        .snapshots()
        .listen(
      (QuerySnapshot<Map<String, dynamic>> snap) {
        _docs = snap.docs
            .map((QueryDocumentSnapshot<Map<String, dynamic>> d) =>
                TravelDocument.fromFirestore(d.id, d.data()))
            .toList()
          ..sort((TravelDocument a, TravelDocument b) =>
              b.updatedAt.compareTo(a.updatedAt));
        _loading = false;
        _lastError = null;
        notifyListeners();
        refreshReminders();
      },
      onError: (Object e) {
        _loading = false;
        _lastError = describeVaultError(e);
        notifyListeners();
      },
    );
    // Trip names for linking + labels (already offline-first).
    unawaited(_trips.loadFor(uid));
    refreshReminders();
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _uid = null;
    _loading = false;
    notifyListeners();
  }

  // ---------------- writes ----------------

  /// Creates the metadata entry. Firestore queues this locally when
  /// offline and syncs automatically with the same stable id — retries
  /// cannot duplicate the document.
  Future<void> createDocument(TravelDocument doc) async {
    await _docRef(doc.userId, doc.id).set(doc.toFirestore());
    unawaited(refreshReminders());
  }

  /// Full-metadata update (edit screen). The stored userId can never be
  /// changed to another user.
  Future<void> updateDocument(TravelDocument doc) async {
    assert(doc.userId == _uid, 'vault: ownership mismatch');
    await _docRef(doc.userId, doc.id).set(doc.toFirestore());
    unawaited(refreshReminders());
  }

  /// Deletes the Storage file first (so no orphan is left behind), then the
  /// metadata. If Storage deletion fails for a real reason, nothing is
  /// deleted and the error propagates to the UI.
  Future<void> deleteDocument(TravelDocument doc) async {
    if (doc.storagePath != null && doc.storagePath!.isNotEmpty) {
      await _storage.deleteVaultFile(doc.storagePath!);
    }
    await _docRef(doc.userId, doc.id).delete();
    for (final int offset in kVaultReminderOffsets) {
      await _notifications.cancelScheduled(vaultReminderId(doc.id, offset));
    }
    _scheduledIds.removeAll(<int>[
      for (final int offset in kVaultReminderOffsets)
        vaultReminderId(doc.id, offset),
    ]);
    unawaited(refreshReminders());
  }

  // ---------------- file upload (orchestrated by screens) ----------------

  /// Starts the resumable Storage upload for [docId]. The caller owns the
  /// returned [Task]: it listens for progress, can cancel, and retries to
  /// the SAME path — so a retried upload can never create duplicates or
  /// orphans.
  Future<Task> startUpload(XFile file, String uid, String docId) =>
      _storage.startVaultUpload(file, uid, docId);

  /// Records a finished upload (URL + path + file info) on the metadata.
  Future<void> completeUpload({
    required String uid,
    required String docId,
    required String fileUrl,
    required String storagePath,
    required String fileName,
    required int fileSize,
  }) async {
    final Map<String, dynamic> patch = <String, dynamic>{
      'fileUrl': fileUrl,
      'storagePath': storagePath,
      'fileName': fileName,
      'fileSize': fileSize,
      'uploadStatus': VaultUploadStatus.uploaded.name,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await _docRef(uid, docId).update(patch);
  }

  /// Removes the file reference after a successful Storage delete
  /// (used by Replace-file when the user saves without a new file, and by
  /// cleanup paths). Keeps the rest of the metadata untouched.
  Future<void> clearFileReference(String uid, String docId) async {
    await _docRef(uid, docId).update(<String, dynamic>{
      'fileUrl': null,
      'storagePath': null,
      'fileName': null,
      'fileSize': null,
      'uploadStatus': VaultUploadStatus.none.name,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Generates a new stable Firestore auto-id BEFORE any write — the same
  /// id is reused across upload retries, so a retried add can never create
  /// duplicate records or duplicate files.
  String newDocumentId() => _db.collection('users').doc().id;

  DocumentReference<Map<String, dynamic>> _docRef(String uid, String docId) =>
      _db.collection('users').doc(uid).collection('travelDocuments').doc(docId);

  // ---------------- reminders ----------------

  /// Re-checks OS notification permission and (re)builds the pending
  /// reminder set: for every document with a future expiry date, one-shot
  /// local notifications at 90 / 30 / 7 / 1 days before expiry, 09:00
  /// device-local. Documents without an expiry date never get reminders.
  /// Called on stream updates and app starts, so reminders self-heal.
  Future<void> refreshReminders() async {
    final String? uid = _uid;
    if (uid == null) return;
    _remindersPermission = await _notifications.ensurePermission();
    final Set<int> previous = Set<int>.of(_scheduledIds);
    _scheduledIds.clear();
    if (!_remindersPermission) {
      for (final int stale in previous) {
        await _notifications.cancelScheduled(stale);
      }
      notifyListeners();
      return;
    }
    final DateTime now = DateTime.now();
    for (final TravelDocument doc in _docs) {
      final DateTime? expiry = doc.expiryDate;
      if (expiry == null || expiry.isBefore(now)) continue;
      for (final DateTime at in vaultReminderTimes(expiry, now)) {
        final int offset = _offsetFor(expiry, at);
        final int id = vaultReminderId(doc.id, offset);
        previous.remove(id);
        final bool ok = await _notifications.schedule(
          id: id,
          title: '${doc.type.emoji} ${doc.type.label} reminder',
          body: '${doc.title} expires on '
              '${expiry.day}/${expiry.month}/${expiry.year}.',
          at: at,
          channel: 'vault',
          payload: 'vault:${doc.id}',
        );
        if (ok) _scheduledIds.add(id);
      }
    }
    for (final int stale in previous) {
      await _notifications.cancelScheduled(stale);
    }
    notifyListeners();
  }

  /// Recovers the offset (90/30/7/1) from the reminder time — reminder
  /// times land exactly on expiry-09:00 minus offset days.
  static int _offsetFor(DateTime expiry, DateTime reminderAt) {
    return DateTime(expiry.year, expiry.month, expiry.day)
        .difference(DateTime(reminderAt.year, reminderAt.month, reminderAt.day))
        .inDays;
  }

  // ---------------- errors ----------------

  /// Honest, specific text for the known failure modes. The most common one
  /// (permission-denied) means the DEPLOYED Firebase rules predate this
  /// feature — the repo rules must be deployed once by the account owner.
  static String describeVaultError(Object e) {
    if (e is FirebaseException && e.code == 'permission-denied') {
      return 'The server security rules for the Document Vault are not '
          'deployed yet, so this device may not read or save vault entries. '
          'Run "bash scripts/deploy-rules.sh" from the project once — no '
          'reinstall is needed.';
    }
    if (e is FirebaseException && e.code == 'unavailable') {
      return 'Could not reach the document service. Check your internet '
          'connection — changes made offline sync automatically.';
    }
    if (e is FirebaseException && e.code == 'unauthenticated') {
      return 'Your session expired. Sign in again to use the vault.';
    }
    return 'Something went wrong while syncing your documents. Check your '
        'internet connection and try again.';
  }

  // ---------------- trip helpers ----------------

  /// Display name of a linked trip from the EXISTING Trip Planner store —
  /// never duplicated in the vault.
  String tripName(String? tripId) {
    if (tripId == null) return '';
    for (final trip in _trips.plans) {
      if (trip.id == tripId) return trip.destination;
    }
    return '';
  }

  List<TravelDocument> docsForTrip(String tripId) =>
      _docs.where((TravelDocument d) => d.tripId == tripId).toList();

  TravelDocument? byId(String? id) {
    if (id == null) return null;
    for (final TravelDocument d in _docs) {
      if (d.id == id) return d;
    }
    return null;
  }
}
