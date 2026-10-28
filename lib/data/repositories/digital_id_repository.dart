import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/digital_id.dart';

/// Digital Emergency ID storage.
///
/// Two documents per ID, on purpose:
///  * `digitalIds/{id}` — the private record (owner + admin only).
///  * `digitalIdPublic/{token}` — the ONLY thing a rescuer can read, and only
///    with the token in hand: the document id is the token itself, the
///    collection cannot be listed. That is what makes the QR safe to verify
///    from any device without exposing every traveller's emergency contact to
///    every signed-in user (which the old single-collection rule did).
class DigitalIdRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _private =>
      _db.collection('digitalIds');

  CollectionReference<Map<String, dynamic>> get _public =>
      _db.collection('digitalIdPublic');

  Future<String> create({
    required String uid,
    required String ownerName,
    String? photoUrl,
    String? emergencyContactName,
    String? emergencyContactPhone,
  }) async {
    final String token = DigitalId.generateToken();
    final DocumentReference<Map<String, dynamic>> ref =
        await _private.add(<String, dynamic>{
      'uid': uid,
      'ownerName': ownerName,
      'token': token,
      'status': 'active',
      'photoUrl': photoUrl,
      'emergencyContactName': emergencyContactName,
      'emergencyContactPhone': emergencyContactPhone,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });

    // Public half. If the deployed rules do not know this collection yet
    // (rules not deployed), the ID still works on-device and the QR still
    // renders — verification will simply report "not found" until the rules
    // are deployed, which is far better than losing the whole ID.
    try {
      await _public.doc(token).set(<String, dynamic>{
        'token': token,
        'uid': uid,
        'ownerName': ownerName,
        'status': 'active',
        'photoUrl': photoUrl,
        'emergencyContactName': emergencyContactName,
        'emergencyContactPhone': emergencyContactPhone,
        'updatedAt': Timestamp.now(),
      });
    } catch (e) {
      debugPrint('digitalIdPublic write failed (deploy firestore.rules): $e');
    }
    return ref.id;
  }

  Stream<List<DigitalId>> watchMine(String uid) => _private
      .where('uid', isEqualTo: uid)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => s.docs
          .map((d) => DigitalId.fromMap(d.id, d.data()))
          .toList());

  /// Verifies a token (the only value contained in the QR code) against the
  /// public half of the record. Returns null when the token is unknown.
  Future<DigitalId?> verify(String rawToken) async {
    final String token = rawToken.trim().toLowerCase();
    if (!DigitalId.isValidTokenShape(token)) return null;
    final DocumentSnapshot<Map<String, dynamic>> snap =
        await _public.doc(token).get();
    final Map<String, dynamic>? data = snap.data();
    if (data == null) {
      // Rules not deployed yet / public doc missing for an ID created before
      // this change: fall back to the legacy query, then give up honestly.
      return _verifyLegacy(token);
    }
    return DigitalId.fromMap(token, data);
  }

  Future<DigitalId?> _verifyLegacy(String token) async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snap =
          await _private.where('token', isEqualTo: token).limit(1).get();
      if (snap.docs.isEmpty) return null;
      final QueryDocumentSnapshot<Map<String, dynamic>> d = snap.docs.first;
      return DigitalId.fromMap(d.id, d.data());
    } catch (_) {
      return null;
    }
  }

  Future<void> setActive(String id, bool active) async {
    final String status = active ? 'active' : 'revoked';
    final DocumentReference<Map<String, dynamic>> ref = _private.doc(id);
    final DocumentSnapshot<Map<String, dynamic>> snap = await ref.get();
    await ref.update(<String, dynamic>{
      'status': status,
      'updatedAt': Timestamp.now(),
    });
    final String? token = snap.data()?['token'] as String?;
    if (token == null || token.isEmpty) return;
    try {
      await _public.doc(token).update(<String, dynamic>{
        'status': status,
        'updatedAt': Timestamp.now(),
      });
    } catch (_) {
      // Public doc may not exist for IDs created before the split; a rescuer
      // then sees the legacy state, never a wrong "active" claim.
    }
  }
}
