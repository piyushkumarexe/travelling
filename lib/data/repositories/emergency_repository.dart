import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/emergency_event.dart';

class EmergencyRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<String> create({
    required String uid,
    required String name,
    required double lat,
    required double lng,
    double? accuracyMeters,
  }) {
    return _db.collection('emergencyEvents').add(<String, dynamic>{
      'uid': uid,
      'name': name,
      'status': 'active',
      'location': <String, dynamic>{
        'lat': lat,
        'lng': lng,
        'accuracy': accuracyMeters,
      },
      'createdAt': Timestamp.now(),
    }).then((ref) => ref.id);
  }

  Stream<List<EmergencyEvent>> watchMine(String uid) => _db
      .collection('emergencyEvents')
      .where('uid', isEqualTo: uid)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) {
        final List<EmergencyEvent> items = s.docs
            .map((d) => EmergencyEvent.fromMap(d.id, d.data()))
            .toList()
          ..sort((EmergencyEvent a, EmergencyEvent b) =>
              b.createdAt.compareTo(a.createdAt));
        return items;
      });

  /// Admin view, newest first.
  Stream<List<EmergencyEvent>> watchAll() => _db
      .collection('emergencyEvents')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => s.docs
          .map((d) => EmergencyEvent.fromMap(d.id, d.data()))
          .toList());

  /// Owner can cancel/resolve their own; admin can resolve (rules enforce).
  Future<void> updateStatus(String id, String status) {
    final Map<String, dynamic> data = <String, dynamic>{
      'status': status,
      'updatedAt': Timestamp.now(),
    };
    if (status == 'resolved' || status == 'cancelled') {
      data['resolvedAt'] = Timestamp.now();
    }
    return _db.collection('emergencyEvents').doc(id).update(data);
  }
}
