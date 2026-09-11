import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Android local notifications with dedicated channels per alert type.
/// Handles notification permission (Android 13+) explicitly and never
/// crashes when the permission is denied.
library;

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Last tapped notification payload (handled when app is opened from a
  /// notification).
  String? lastTappedPayload;

  Future<void> init() async {
    try {
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const InitializationSettings settings = InitializationSettings(
        android: androidSettings,
        iOS: DarwinInitializationSettings(),
      );
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          lastTappedPayload = response.payload;
        },
      );
      _ready = true;
    } catch (e) {
      debugPrint('NotificationService init failed: $e');
    }
  }

  /// Requests POST_NOTIFICATIONS on Android 13+. Returns true when the user
  /// may receive notifications.
  Future<bool> ensurePermission() async {
    try {
      final AndroidFlutterLocalNotificationsPlugin? android = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true;
      final bool? enabled = await android.areNotificationsEnabled();
      if (enabled ?? true) return true;
      final bool? granted = await android.requestNotificationsPermission();
      return granted ?? false;
    } catch (e) {
      debugPrint('NotificationService permission check failed: $e');
      return false;
    }
  }

  /// Shows a real Android notification.
  /// [channel] is one of: safety, geofence, emergency, incident, weather,
  /// general.
  void show({
    required int id,
    required String title,
    required String body,
    required String channel,
    String? payload,
    bool important = false,
  }) {
    if (!_ready) return;
    try {
      final AndroidNotificationDetails details = AndroidNotificationDetails(
        channel,
        _channelName(channel),
        channelDescription: 'Yatrawise $_channelName(channel.toLowerCase())',
        importance: important ? Importance.max : Importance.high,
        priority: important ? Priority.high : Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
      );
      _plugin.show(
        id,
        title,
        body,
        NotificationDetails(android: details),
        payload: payload,
      );
    } catch (e) {
      debugPrint('NotificationService.show failed: $e');
    }
  }

  static String _channelName(String id) => switch (id) {
        'safety' => 'Safety alerts',
        'geofence' => 'Geofence warnings',
        'emergency' => 'Emergency (SOS)',
        'incident' => 'Incident updates',
        'weather' => 'Weather alerts',
        _ => 'General',
      };
}
