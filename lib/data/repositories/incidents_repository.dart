import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/incident.dart';

class IncidentsRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<String> create(Incident incident) =>
      _db.collection('incidents').add(incident.toMap()).then((ref) => ref.id);

  /// The current user's own reports (permission enforced by rules:
  /// list = any signed-in user, get = owner or admin → user only sees own).
  Stream<List<Incident>> watchMine(String uid) => _db
      .collection('incidents')
      .where('uid', isEqualTo: uid)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) {
        final List<Incident> items =
            s.docs.map((d) => Incident.fromMap(d.id, d.data())).toList()
          ..sort((Incident a, Incident b) =>
              b.createdAt.compareTo(a.createdAt));
        return items;
      });

  /// Admin view, newest first.
  Stream<List<Incident>> watchAll() => _db
      .collection('incidents')
      .orderBy('createdAt', descending: true)
      .limit(200)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => s.docs
          .map((d) => Incident.fromMap(d.id, d.data()))
          .toList());

  Stream<Incident?> watchOne(String id) => _db
      .collection('incidents')
      .doc(id)
      .snapshots()
      .map((DocumentSnapshot<Map<String, dynamic>> d) =>
          d.exists ? Incident.fromMap(d.id, d.data()!) : null);

  Future<Incident?> get(String id) async {
    final DocumentSnapshot<Map<String, dynamic>> d =
        await _db.collection('incidents').doc(id).get();
    return d.exists ? Incident.fromMap(d.id, d.data()!) : null;
  }

  /// Admin-only in practice (enforced by security rules).
  Future<void> updateStatus(String id, String status) =>
      _db.collection('incidents').doc(id).update(<String, dynamic>{
        'status': status,
        'updatedAt': Timestamp.now(),
      });
}
