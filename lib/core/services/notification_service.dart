import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Android local notifications with dedicated channels per alert type.
/// Handles notification permission (Android 13+) explicitly and never
/// crashes when the permission is denied.

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _tzReady = false;

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
      await _ensureChannels();
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
        // NOTE: this used to be written as 'Tourism $_channelName(...)' —
        // interpolating the *function* instead of calling it, which printed
        // "Tourism Closure: (String) => String" as the channel description.
        channelDescription: _channelDescription(channel),
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
        'vault' => 'Document expiry reminders',
        _ => 'General',
      };

  // The app is Tourism — channel names are visible in Android's
  // notification settings, so they must match the launcher label.
  static String _channelDescription(String id) =>
      'Tourism ${_channelName(id)}';

  /// Android notification channels are created up-front, once.
  ///
  /// Without this the OS auto-creates every channel on first show with DEFAULT
  /// importance, and channel importance can never be changed afterwards — so a
  /// SOS or geofence alert could arrive as a silent heads-up notification even
  /// though the code asked for max importance. Creating them here is what
  /// actually gives 'emergency' / 'safety' their loud behaviour and puts tidy
  /// names in System settings → App → Notifications.
  Future<void> _ensureChannels() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    for (final _ChannelSpec c in _channelSpecs) {
      try {
        await android.createNotificationChannel(
          // flutter_local_notifications v17: (channelId, name, {…}) —
          // importance/description are NAMED parameters.
          AndroidNotificationChannel(
            c.id,
            c.name,
            description: c.description,
            // v17 defaults are already playSound: true / enableVibration: true,
            // so only the importance that matters per channel type is set.
            importance: c.importance,
          ),
        );
      } catch (e) {
        debugPrint('NotificationService channel ${c.id} failed: $e');
      }
    }
  }

  static const List<_ChannelSpec> _channelSpecs = <_ChannelSpec>[
    _ChannelSpec('general', 'General', Importance.defaultImportance),
    _ChannelSpec('safety', 'Safety alerts', Importance.high),
    _ChannelSpec('geofence', 'Geofence warnings', Importance.high),
    _ChannelSpec('emergency', 'Emergency (SOS)', Importance.max),
    _ChannelSpec('incident', 'Incident updates', Importance.defaultImportance),
    _ChannelSpec('weather', 'Weather alerts', Importance.defaultImportance),
    _ChannelSpec('vault', 'Document expiry reminders',
        Importance.defaultImportance),
  ];

  /// Schedules a one-shot notification. [at] is device-local wall-clock
  /// time. Uses inexact scheduling (no special alarm permission) and
  /// converts the local time using the device's current UTC offset (the
  /// app has no native IANA timezone lookup; India has no DST so this is
  /// exact for the primary market). Returns true when scheduled.
  Future<bool> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime at,
    String channel = 'general',
    String? payload,
  }) async {
    if (!_ready) return false;
    try {
      if (!_tzReady) {
        tzdata.initializeTimeZones();
        _tzReady = true;
      }
      final tz.TZDateTime when = tz.TZDateTime.utc(
              at.year, at.month, at.day, at.hour, at.minute)
          .subtract(DateTime.now().timeZoneOffset);
      if (!when.isAfter(tz.TZDateTime.now(tz.local))) return false;
      final AndroidNotificationDetails details = AndroidNotificationDetails(
        channel,
        _channelName(channel),
        channelDescription: _channelDescription(channel),
        importance: Importance.high,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
      );
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        NotificationDetails(android: details),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
      return true;
    } catch (e) {
      debugPrint('NotificationService.schedule failed: $e');
      return false;
    }
  }

  /// Cancels a pending scheduled notification (no-op when none).
  Future<void> cancelScheduled(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }
}

/// One Android notification channel: id, human name and the importance the
/// channel is created with (see [_ensureChannels]).
class _ChannelSpec {
  const _ChannelSpec(this.id, this.name, this.importance);

  final String id;
  final String name;
  final Importance importance;

  String get description => 'Tourism $name';
}
