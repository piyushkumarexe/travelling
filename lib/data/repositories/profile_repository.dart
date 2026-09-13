import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/profile.dart';

class ProfileRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<Profile?> watch(String uid) =>
      _db.collection('profiles').doc(uid).snapshots().map(
            (DocumentSnapshot<Map<String, dynamic>> d) =>
                d.exists ? Profile.fromMap(uid, d.data()) : null,
          );

  Future<Profile?> get(String uid) async {
    final DocumentSnapshot<Map<String, dynamic>> d =
        await _db.collection('profiles').doc(uid).get();
    return d.exists ? Profile.fromMap(uid, d.data()) : null;
  }

  Future<void> update(
    String uid, {
    required String name,
    String? photoUrl,
    required String language,
    required String emergencyContactName,
    required String emergencyContactPhone,
    required List<String> interests,
    required String budget,
    required String travelStyle,
  }) {
    return _db.collection('profiles').doc(uid).update(<String, dynamic>{
      'name': name,
      'photoUrl': photoUrl,
      'language': language,
      'emergencyContactName': emergencyContactName,
      'emergencyContactPhone': emergencyContactPhone,
      'interests': interests,
      'budget': budget,
      'travelStyle': travelStyle,
      'updatedAt': Timestamp.now(),
    });
  }

  /// Persists only the preferred vehicle (bike / car / auto) — used by the
  /// dedicated Vehicle tab.
  Future<void> setVehicle(String uid, String vehicle) {
    return _db.collection('profiles').doc(uid).set(
      <String, dynamic>{
        'vehicle': vehicle,
        'updatedAt': Timestamp.now(),
      },
      SetOptions(merge: true),
    );
  }

  /// Focused upsert of the SOS/emergency contact — the SINGLE source of truth
  /// shared by the SOS screen, Profile and Power-Off Safety Location. Uses
  /// merge so it never clobbers other profile fields, and creates the
  /// profiles/{uid} document if it does not exist yet.
  Future<void> setEmergencyContact(
    String uid, {
    required String name,
    required String phone,
  }) {
    return _db.collection('profiles').doc(uid).set(
      <String, dynamic>{
        'emergencyContactName': name,
        'emergencyContactPhone': phone,
        'updatedAt': Timestamp.now(),
      },
      SetOptions(merge: true),
    );
  }

  /// Clears the SOS/emergency contact (same merge semantics).
  Future<void> clearEmergencyContact(String uid) {
    return _db.collection('profiles').doc(uid).set(
      <String, dynamic>{
        'emergencyContactName': '',
        'emergencyContactPhone': '',
        'updatedAt': Timestamp.now(),
      },
      SetOptions(merge: true),
    );
  }
}
