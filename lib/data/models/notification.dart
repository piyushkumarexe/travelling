import 'package:cloud_firestore/cloud_firestore.dart';

/// In-app notification record (mirrored to Android notifications).
///
/// Stored per user in the subcollection users/{uid}/notifications so each
/// user can only ever read their own history (enforced by security rules).

class AppNotification {
  AppNotification({
    required this.id,
    required this.uid,
    required this.title,
    required this.body,
    required this.type,
    required this.createdAt,
    this.read = false,
    this.payload = const <String, dynamic>{},
  });

  final String id;
  final String uid;

  /// safety_alert | geofence | incident | emergency | weather | info
  final String title;
  final String body;
  final String type;
  final bool read;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  factory AppNotification.fromMap(String id, Map<String, dynamic> m) =>
      AppNotification(
        id: id,
        uid: (m['uid'] as String?) ?? '',
        title: (m['title'] as String?) ?? 'Notification',
        body: (m['body'] as String?) ?? '',
        type: (m['type'] as String?) ?? 'info',
        read: (m['read'] as bool?) ?? false,
        payload: (m['payload'] is Map)
            ? (m['payload'] as Map).map(
                (Object? k, Object? v) => MapEntry(k.toString(), v),
              )
            : <String, dynamic>{},
        createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      );
}
