import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/network/api_client.dart';
import '../models/digital_id.dart';

class DigitalIdRepository {
  DigitalIdRepository(this._api);

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final ApiClient _api;

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

  /// Looks up a scanned QR token through the authenticated, rate-limited
  /// backend. Firestore rules deliberately do not let clients list or read
  /// other users' emergency contact records.
  Future<DigitalId?> verify(String rawToken) async {
    final String token = rawToken.trim().toLowerCase();
    if (!DigitalId.isValidTokenShape(token)) return null;
    final Map<String, dynamic> response =
        await _api.post('/digitalIdVerify', <String, dynamic>{'token': token});
    final dynamic raw = response['digitalId'];
    if (raw is! Map) return null;
    return DigitalId.fromMap(
      '',
      raw.map((Object? key, Object? value) => MapEntry(key.toString(), value)),
    );
  }

  Future<void> setActive(String id, bool active) => _db
      .collection('digitalIds')
      .doc(id)
      .update(<String, dynamic>{
        'status': active ? 'active' : 'revoked',
        'updatedAt': Timestamp.now(),
      });
}
