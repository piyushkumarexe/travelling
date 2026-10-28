import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/digital_id.dart';

class DigitalIdRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<String> create({
    required String uid,
    required String ownerName,
    String? photoUrl,
    String? emergencyContactName,
    String? emergencyContactPhone,
  }) {
    return _db.collection('digitalIds').add(<String, dynamic>{
      'uid': uid,
      'ownerName': ownerName,
      'token': DigitalId.generateToken(),
      'status': 'active',
      'photoUrl': photoUrl,
      'emergencyContactName': emergencyContactName,
      'emergencyContactPhone': emergencyContactPhone,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    }).then((ref) => ref.id);
  }

  Stream<List<DigitalId>> watchMine(String uid) => _db
      .collection('digitalIds')
      .where('uid', isEqualTo: uid)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => s.docs
          .map((d) => DigitalId.fromMap(d.id, d.data()))
          .toList());

  /// Verifies a token (the only value contained in the QR code) against the
  /// live digitalIds collection. Returns null when the token is unknown.
  Future<DigitalId?> verify(String rawToken) async {
    final String token = rawToken.trim().toLowerCase();
    if (!DigitalId.isValidTokenShape(token)) return null;
    final QuerySnapshot<Map<String, dynamic>> snap = await _db
        .collection('digitalIds')
        .where('token', isEqualTo: token)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    final QueryDocumentSnapshot<Map<String, dynamic>> d = snap.docs.first;
    return DigitalId.fromMap(d.id, d.data());
  }

  Future<void> setActive(String id, bool active) => _db
      .collection('digitalIds')
      .doc(id)
      .update(<String, dynamic>{
        'status': active ? 'active' : 'revoked',
        'updatedAt': Timestamp.now(),
      });
}
