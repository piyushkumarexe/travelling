import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/digital_id.dart';

/// Private Digital IDs and their minimal token-only public verification half.
class DigitalIdRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _private =>
      _db.collection('digitalIds');

  CollectionReference<Map<String, dynamic>> get _public =>
      _db.collection('digitalIdPublic');

  Map<String, dynamic> _publicData(
    DigitalId id, {
    String? status,
  }) =>
      <String, dynamic>{
        'token': id.token,
        'recordId': id.id,
        'ownerName': id.ownerName,
        'status': status ?? id.status,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  Future<String> create({
    required String uid,
    required String ownerName,
    String? photoUrl,
    String? photoPath,
    String? emergencyContactName,
    String? emergencyContactPhone,
  }) async {
    final String token = DigitalId.generateToken();
    final DocumentReference<Map<String, dynamic>> ref = _private.doc();
    final DigitalId pending = DigitalId(
      id: ref.id,
      uid: uid,
      ownerName: ownerName,
      token: token,
      status: 'active',
      createdAt: DateTime.now(),
    );
    final WriteBatch batch = _db.batch();
    batch.set(ref, <String, dynamic>{
      'uid': uid,
      'ownerName': ownerName,
      'token': token,
      'status': 'active',
      'photoUrl': photoUrl,
      'photoPath': photoPath,
      'emergencyContactName': emergencyContactName,
      'emergencyContactPhone': emergencyContactPhone,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.set(_public.doc(token), _publicData(pending));
    // If either half fails, neither becomes visible. The UI must not invent a
    // local QR identity that a rescuer could never verify.
    await batch.commit();
    return ref.id;
  }

  Stream<List<DigitalId>> watchMine(String uid) => _private
      .where('uid', isEqualTo: uid)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> snapshot) {
        final List<DigitalId> ids = snapshot.docs
            .map((doc) => DigitalId.fromMap(doc.id, doc.data()))
            .toList();
        ids.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return ids;
      });

  /// Repairs pre-split/legacy public records without copying private fields.
  /// A valid current record is left untouched.
  Future<void> ensurePublic(DigitalId id) async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await _public.doc(id.token).get();
    final Map<String, dynamic>? data = snapshot.data();
    final bool current = data != null &&
        data.length == 5 &&
        data['token'] == id.token &&
        data['recordId'] == id.id &&
        data['ownerName'] == id.ownerName &&
        data['status'] == id.status;
    if (!current) await _public.doc(id.token).set(_publicData(id));
  }

  /// Public verification only. There is deliberately no private-collection
  /// fallback: that would expose emergency contacts and bypass token privacy.
  Future<DigitalId?> verify(String rawToken) async {
    final String token = rawToken.trim().toLowerCase();
    if (!DigitalId.isValidTokenShape(token)) return null;
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await _public.doc(token).get();
    final Map<String, dynamic>? data = snapshot.data();
    return data == null ? null : DigitalId.fromMap(token, data);
  }

  Future<void> setActive(String id, bool active) async {
    final DocumentReference<Map<String, dynamic>> ref = _private.doc(id);
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await ref.get();
    final Map<String, dynamic>? data = snapshot.data();
    if (data == null) {
      throw StateError('This Digital ID no longer exists.');
    }
    final DigitalId current = DigitalId.fromMap(id, data);
    if (!DigitalId.isValidTokenShape(current.token)) {
      throw StateError('This legacy ID has no valid verification token.');
    }
    final String status = active ? 'active' : 'revoked';
    final WriteBatch batch = _db.batch();
    batch.update(ref, <String, dynamic>{
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.set(
      _public.doc(current.token),
      _publicData(current, status: status),
    );
    await batch.commit();
  }
}
