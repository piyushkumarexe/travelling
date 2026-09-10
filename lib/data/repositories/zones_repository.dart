import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/safety_zone.dart';

/// Safety zones are admin-managed; regular users only read them.
class ZonesRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<List<SafetyZone>> watchAll() => _db
      .collection('safetyZones')
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) {
        final List<SafetyZone> zones = s.docs
            .map((DocumentSnapshot<Map<String, dynamic>> d) =>
                SafetyZone.fromMap(d.id, d.data()!))
            .toList()
          ..sort((SafetyZone a, SafetyZone b) =>
              (b.createdAt?.millisecondsSinceEpoch ?? 0) -
              (a.createdAt?.millisecondsSinceEpoch ?? 0));
        return zones;
      });

  Future<List<SafetyZone>> getAll() async {
    final QuerySnapshot<Map<String, dynamic>> s =
        await _db.collection('safetyZones').get();
    return s.docs
        .map((DocumentSnapshot<Map<String, dynamic>> d) =>
            SafetyZone.fromMap(d.id, d.data()!))
        .toList();
  }

  Future<String> create(Map<String, dynamic> data,
      {required String createdByName}) {
    data['createdByName'] = createdByName;
    data['createdAt'] = Timestamp.now();
    data['updatedAt'] = Timestamp.now();
    return _db.collection('safetyZones').add(data).then((ref) => ref.id);
  }

  Future<void> update(String id, Map<String, dynamic> data) {
    data['updatedAt'] = Timestamp.now();
    return _db.collection('safetyZones').doc(id).update(data);
  }

  Future<void> remove(String id) => _db.collection('safetyZones').doc(id).delete();
}
