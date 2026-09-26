import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'journey_operations_models.dart';

class JourneyOperationsService {
  JourneyOperationsService({FirebaseFirestore? firestore})
      : _firestore = firestore;

  final FirebaseFirestore? _firestore;
  final Set<String> _profileFallbackUsers = <String>{};
  final Set<String> _localFallbackUsers = <String>{};
  final Map<String, List<JourneyOperation>> _latest =
      <String, List<JourneyOperation>>{};
  final Map<String, StreamController<List<JourneyOperation>>> _localStreams =
      <String, StreamController<List<JourneyOperation>>>{};

  static const String _localPrefix = 'journey_operations.v1.';

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _collection(String uid) =>
      _db.collection('users').doc(uid).collection('journeyOperations');

  DocumentReference<Map<String, dynamic>> _profile(String uid) =>
      _db.collection('profiles').doc(uid);

  /// Uses the dedicated owner-only collection when its rules are deployed.
  /// Older rules fall back first to the owner's profile and finally to the
  /// app's private on-device preference storage. The feature never
  /// becomes a developer-instruction dead screen merely because cloud rules
  /// lag behind the APK.
  Stream<List<JourneyOperation>> watch(String uid) async* {
    try {
      await for (final QuerySnapshot<Map<String, dynamic>> snapshot
          in _collection(uid)
              .orderBy('updatedAt', descending: true)
              .limit(300)
              .snapshots()) {
        final List<JourneyOperation> items = snapshot.docs
            .map((QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                JourneyOperation.fromFirestore(document.data()))
            .where((JourneyOperation item) => item.id.isNotEmpty)
            .toList(growable: false);
        _latest[uid] = items;
        yield items;
      }
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      _profileFallbackUsers.add(uid);
      try {
        await for (final DocumentSnapshot<Map<String, dynamic>> snapshot
            in _profile(uid).snapshots()) {
          final Object? raw = snapshot.data()?['journeyOperationsV1'];
          final List<JourneyOperation> items = raw is List
              ? raw
                  .whereType<Map>()
                  .map((Map item) => JourneyOperation.fromFirestore(
                      Map<String, dynamic>.from(item)))
                  .where((JourneyOperation item) => item.id.isNotEmpty)
                  .toList()
              : <JourneyOperation>[];
          items.sort((JourneyOperation a, JourneyOperation b) =>
              b.updatedAt.compareTo(a.updatedAt));
          _latest[uid] = items;
          yield List<JourneyOperation>.unmodifiable(items);
        }
      } on FirebaseException catch (profileError) {
        if (profileError.code != 'permission-denied') rethrow;
        // The currently deployed rules can predate both server locations.
        // Keep all twelve tools fully usable on this phone instead of showing
        // a developer-only "deploy rules" dead screen.
        _localFallbackUsers.add(uid);
        final List<JourneyOperation> local = await _readLocal(uid);
        _latest[uid] = local;
        yield List<JourneyOperation>.unmodifiable(local);
        yield* _localStream(uid).stream;
      }
    }
  }

  Future<void> save({
    required String uid,
    required JourneyToolKind kind,
    required String title,
    required String detail,
    required String extra,
    JourneyOperation? existing,
  }) async {
    final String cleanTitle = title.trim();
    if (cleanTitle.isEmpty) throw ArgumentError('A title is required.');
    if (cleanTitle.length > 160 || detail.length > 2000 || extra.length > 500) {
      throw ArgumentError('One or more fields are too long.');
    }
    final DateTime now = DateTime.now();
    final String id = existing?.id ?? _collection(uid).doc().id;
    final JourneyOperation item = JourneyOperation(
      id: id,
      userId: uid,
      kind: kind,
      title: cleanTitle,
      detail: detail.trim(),
      extra: extra.trim(),
      completed: existing?.completed ?? false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    if (_localFallbackUsers.contains(uid)) {
      await _upsertLocal(uid, item);
      return;
    }
    if (_profileFallbackUsers.contains(uid)) {
      try {
        await _upsertFallback(uid, item);
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
        _localFallbackUsers.add(uid);
        await _upsertLocal(uid, item);
      }
      return;
    }
    try {
      await _collection(uid).doc(id).set(item.toFirestore());
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      _profileFallbackUsers.add(uid);
      try {
        await _upsertFallback(uid, item);
      } on FirebaseException catch (profileError) {
        if (profileError.code != 'permission-denied') rethrow;
        _localFallbackUsers.add(uid);
        await _upsertLocal(uid, item);
      }
    }
  }

  Future<void> setCompleted({
    required String uid,
    required JourneyOperation item,
    required bool completed,
  }) async {
    final JourneyOperation updated = item.copyWith(completed: completed);
    if (_localFallbackUsers.contains(uid)) {
      await _upsertLocal(uid, updated);
      return;
    }
    if (_profileFallbackUsers.contains(uid)) {
      try {
        await _upsertFallback(uid, updated);
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
        _localFallbackUsers.add(uid);
        await _upsertLocal(uid, updated);
      }
      return;
    }
    try {
      await _collection(uid).doc(item.id).update(<String, dynamic>{
        'completed': completed,
        'updatedAt': updated.updatedAt.millisecondsSinceEpoch,
      });
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      _profileFallbackUsers.add(uid);
      try {
        await _upsertFallback(uid, updated);
      } on FirebaseException catch (profileError) {
        if (profileError.code != 'permission-denied') rethrow;
        _localFallbackUsers.add(uid);
        await _upsertLocal(uid, updated);
      }
    }
  }

  Future<void> delete(String uid, String id) async {
    if (_localFallbackUsers.contains(uid)) {
      await _deleteLocal(uid, id);
      return;
    }
    if (_profileFallbackUsers.contains(uid)) {
      try {
        await _deleteFallback(uid, id);
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
        _localFallbackUsers.add(uid);
        await _deleteLocal(uid, id);
      }
      return;
    }
    try {
      await _collection(uid).doc(id).delete();
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      _profileFallbackUsers.add(uid);
      try {
        await _deleteFallback(uid, id);
      } on FirebaseException catch (profileError) {
        if (profileError.code != 'permission-denied') rethrow;
        _localFallbackUsers.add(uid);
        await _deleteLocal(uid, id);
      }
    }
  }

  Future<void> _upsertFallback(String uid, JourneyOperation item) async {
    final List<JourneyOperation> items =
        List<JourneyOperation>.from(_latest[uid] ?? const <JourneyOperation>[])
          ..removeWhere((JourneyOperation value) => value.id == item.id)
          ..insert(0, item);
    if (items.length > 300) items.removeRange(300, items.length);
    _latest[uid] = items;
    await _profile(uid).set(<String, dynamic>{
      'journeyOperationsV1': items
          .map((JourneyOperation value) => value.toFirestore())
          .toList(growable: false),
    }, SetOptions(merge: true));
  }

  Future<void> _deleteFallback(String uid, String id) async {
    final List<JourneyOperation> items =
        List<JourneyOperation>.from(_latest[uid] ?? const <JourneyOperation>[])
          ..removeWhere((JourneyOperation value) => value.id == id);
    _latest[uid] = items;
    await _profile(uid).set(<String, dynamic>{
      'journeyOperationsV1': items
          .map((JourneyOperation value) => value.toFirestore())
          .toList(growable: false),
    }, SetOptions(merge: true));
  }

  StreamController<List<JourneyOperation>> _localStream(String uid) =>
      _localStreams.putIfAbsent(
        uid,
        () => StreamController<List<JourneyOperation>>.broadcast(),
      );

  Future<List<JourneyOperation>> _readLocal(String uid) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('$_localPrefix$uid');
      if (raw == null) return <JourneyOperation>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <JourneyOperation>[];
      final List<JourneyOperation> items = decoded
          .whereType<Map>()
          .map((Map value) => JourneyOperation.fromFirestore(
              Map<String, dynamic>.from(value)))
          .where((JourneyOperation item) => item.id.isNotEmpty)
          .toList()
        ..sort((JourneyOperation a, JourneyOperation b) =>
            b.updatedAt.compareTo(a.updatedAt));
      return items;
    } catch (_) {
      return <JourneyOperation>[];
    }
  }

  Future<void> _writeLocal(
      String uid, List<JourneyOperation> items) async {
    _latest[uid] = List<JourneyOperation>.unmodifiable(items);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_localPrefix$uid',
      jsonEncode(items
          .map((JourneyOperation item) => item.toFirestore())
          .toList(growable: false)),
    );
    _localStream(uid).add(List<JourneyOperation>.unmodifiable(items));
  }

  Future<void> _upsertLocal(String uid, JourneyOperation item) async {
    final List<JourneyOperation> items =
        List<JourneyOperation>.from(_latest[uid] ?? await _readLocal(uid))
          ..removeWhere((JourneyOperation value) => value.id == item.id)
          ..insert(0, item);
    if (items.length > 300) items.removeRange(300, items.length);
    await _writeLocal(uid, items);
  }

  Future<void> _deleteLocal(String uid, String id) async {
    final List<JourneyOperation> items =
        List<JourneyOperation>.from(_latest[uid] ?? await _readLocal(uid))
          ..removeWhere((JourneyOperation value) => value.id == id);
    await _writeLocal(uid, items);
  }
}
