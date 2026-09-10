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
}
