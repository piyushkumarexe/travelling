import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/notification.dart';

/// In-app notification history, stored per user at
/// users/{uid}/notifications (users can only read their own — rules).
class NotificationsRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<List<AppNotification>> watchMine(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('notifications')
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) {
        final List<AppNotification> items = s.docs
            .map((d) => AppNotification.fromMap(d.id, d.data()))
            .toList()
          ..sort((AppNotification a, AppNotification b) =>
              b.createdAt.compareTo(a.createdAt));
        return items;
      });

  Future<String> add({
    required String uid,
    required String title,
    required String body,
    required String type,
    Map<String, dynamic>? payload,
  }) {
    return _db
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .add(<String, dynamic>{
          'uid': uid,
          'title': title,
          'body': body,
          'type': type,
          'read': false,
          'payload': payload ?? <String, dynamic>{},
          'createdAt': Timestamp.now(),
        })
        .then((ref) => ref.id);
  }

  Future<void> markRead(String uid, String id) => _db
      .collection('users')
      .doc(uid)
      .collection('notifications')
      .doc(id)
      .update(<String, dynamic>{'read': true});

  Future<void> markAllRead(String uid, List<String> ids) async {
    if (ids.isEmpty) return;
    final WriteBatch batch = _db.batch();
    for (final String id in ids) {
      batch.update(
        _db.collection('users').doc(uid).collection('notifications').doc(id),
        <String, dynamic>{'read': true},
      );
    }
    await batch.commit();
  }
}
