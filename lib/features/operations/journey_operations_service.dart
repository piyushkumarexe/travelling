import 'package:cloud_firestore/cloud_firestore.dart';

import 'journey_operations_models.dart';

class JourneyOperationsService {
  JourneyOperationsService({FirebaseFirestore? firestore})
      : _firestore = firestore;

  final FirebaseFirestore? _firestore;
  final Set<String> _profileFallbackUsers = <String>{};
  final Map<String, List<JourneyOperation>> _latest =
      <String, List<JourneyOperation>>{};

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _collection(String uid) =>
      _db.collection('users').doc(uid).collection('journeyOperations');

  DocumentReference<Map<String, dynamic>> _profile(String uid) =>
      _db.collection('profiles').doc(uid);

  /// Uses the dedicated owner-only collection when its rules are deployed.
  /// Existing installations whose server rules predate this feature
  /// transparently use an owner-only field in profiles/{uid}; unlike the old
  /// screen, the feature stays functional and still syncs across devices.
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
    if (_profileFallbackUsers.contains(uid)) {
      await _upsertFallback(uid, item);
      return;
    }
    try {
      await _collection(uid).doc(id).set(item.toFirestore());
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      _profileFallbackUsers.add(uid);
      await _upsertFallback(uid, item);
    }
  }

  Future<void> setCompleted({
    required String uid,
    required JourneyOperation item,
    required bool completed,
  }) async {
    final JourneyOperation updated = item.copyWith(completed: completed);
    if (_profileFallbackUsers.contains(uid)) {
      await _upsertFallback(uid, updated);
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
      await _upsertFallback(uid, updated);
    }
  }

  Future<void> delete(String uid, String id) async {
    if (_profileFallbackUsers.contains(uid)) {
      await _deleteFallback(uid, id);
      return;
    }
    try {
      await _collection(uid).doc(id).delete();
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      _profileFallbackUsers.add(uid);
      await _deleteFallback(uid, id);
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
}
