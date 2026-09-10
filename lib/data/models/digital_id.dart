import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

/// A Digital Emergency ID.
///
/// The QR code rendered from this profile contains ONLY [token] (a
/// cryptographically random 64-hex-char identifier) — never the name,
/// contact or other private data. Verification is done server-side against
/// the `digitalIds` collection.
library;

class DigitalId {
  DigitalId({
    required this.id,
    required this.uid,
    required this.ownerName,
    required this.token,
    required this.status,
    required this.createdAt,
    this.photoUrl,
    this.emergencyContactName,
    this.emergencyContactPhone,
  });

  final String id;
  final String uid;
  final String ownerName;

  /// 64 hex chars — the only value embedded in the QR code.
  final String token;

  /// active | revoked
  final String status;
  final String? photoUrl;
  final String? emergencyContactName;
  final String? emergencyContactPhone;
  final DateTime createdAt;

  bool get isActive => status == 'active';

  factory DigitalId.fromMap(String id, Map<String, dynamic> m) => DigitalId(
        id: id,
        uid: (m['uid'] as String?) ?? '',
        ownerName: (m['ownerName'] as String?) ?? '',
        token: (m['token'] as String?) ?? '',
        status: (m['status'] as String?) ?? 'revoked',
        photoUrl: m['photoUrl'] as String?,
        emergencyContactName: m['emergencyContactName'] as String?,
        emergencyContactPhone: m['emergencyContactPhone'] as String?,
        createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      );

  /// Cryptographically random 256-bit identifier.
  static String generateToken() {
    final Random r = Random.secure();
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 32; i++) {
      sb.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static bool isValidTokenShape(String token) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(token);
}
