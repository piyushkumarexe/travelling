import 'package:cloud_firestore/cloud_firestore.dart';

import 'journey_operations_models.dart';

class JourneyOperationsService {
  JourneyOperationsService({FirebaseFirestore? firestore})
      : _firestore = firestore;

  final FirebaseFirestore? _firestore;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _collection(String uid) =>
      _db.collection('users').doc(uid).collection('journeyOperations');

  Stream<List<JourneyOperation>> watch(String uid) => _collection(uid)
      .orderBy('updatedAt', descending: true)
      .limit(300)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> snapshot) => snapshot.docs
          .map((QueryDocumentSnapshot<Map<String, dynamic>> document) =>
              JourneyOperation.fromFirestore(document.data()))
          .where((JourneyOperation item) => item.id.isNotEmpty)
          .toList(growable: false));

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
    final DocumentReference<Map<String, dynamic>> reference = existing == null
        ? _collection(uid).doc()
        : _collection(uid).doc(existing.id);
    final JourneyOperation item = JourneyOperation(
      id: reference.id,
      userId: uid,
      kind: kind,
      title: cleanTitle,
      detail: detail.trim(),
      extra: extra.trim(),
      completed: existing?.completed ?? false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await reference.set(item.toFirestore());
  }

  Future<void> setCompleted({
    required String uid,
    required JourneyOperation item,
    required bool completed,
  }) =>
      _collection(uid).doc(item.id).update(<String, dynamic>{
        'completed': completed,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });

  Future<void> delete(String uid, String id) =>
      _collection(uid).doc(id).delete();
}
