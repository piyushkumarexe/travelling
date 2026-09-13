import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../data/repositories/emergency_repository.dart';
import '../../data/repositories/notifications_repository.dart';
import '../utils/sos_messages.dart';
import 'location_service.dart';
import 'notification_service.dart';
import 'settings_service.dart';
import 'sms_service.dart';

/// Live location sharing with the SOS contact.
///
/// Started from the in-app navigation flow ("Do you want to share your live
/// location with your SOS contact?"). While active it:
///
///   1. Writes fresh GPS coordinates to the cloud event every ~45 s
///      (emergencyEvents doc — visible to the traveler and authorized
///      administrators, same collection the SOS flow uses).
///   2. Sends an SMS with the latest coordinates + a Google Maps link to the
///      SOS contact immediately, then every 5 minutes. SMS works even when
///      the traveler has no mobile data.
///   3. Posts an in-app + Android notification so sharing is never secret.
///
/// Sharing stops on [stop], on sign-out, or when the app process is killed
/// (the service is deliberately in-process — no hidden tracking).
class LiveLocationShareService extends ChangeNotifier {
  LiveLocationShareService({
    required this.locationService,
    required this.emergencyRepository,
    required this.notificationsRepository,
    required this.notificationService,
    required this.settings,
    required this.smsService,
    required this.currentUid,
  });

  final LocationService locationService;
  final EmergencyRepository emergencyRepository;
  final NotificationsRepository notificationsRepository;
  final NotificationService notificationService;
  final SettingsService settings;
  final SmsService smsService;
  final String Function() currentUid;

  /// How often the cloud event is refreshed with a new GPS fix.
  static const Duration cloudRefreshInterval = Duration(seconds: 45);

  /// How often a fresh SMS with coordinates is sent to the SOS contact.
  static const Duration smsInterval = Duration(minutes: 5);

  bool _active = false;
  String? _eventId;
  String? _destinationName;
  String _reason = 'navigation';
  String _travelerName = 'Traveler';
  Position? _lastPosition;
  DateTime? _startedAt;
  DateTime? _lastSmsAt;
  int _smsSent = 0;
  int _cloudUpdates = 0;
  String? _lastError;
  bool _smsEnabled = false;

  Timer? _cloudTimer;
  Timer? _smsTimer;

  bool get active => _active;
  String? get destinationName => _destinationName;
  Position? get lastPosition => _lastPosition;
  DateTime? get startedAt => _startedAt;
  DateTime? get lastSmsAt => _lastSmsAt;
  int get smsSent => _smsSent;
  int get cloudUpdates => _cloudUpdates;
  String? get lastError => _lastError;

  /// False when the SEND_SMS permission is missing — sharing still runs via
  /// the cloud event, but the contact is not reached by SMS.
  bool get smsEnabled => _smsEnabled;

  String get sosContactName => settings.sosContactName.trim();
  String get sosContactPhone => settings.sosContactPhone.trim();
  bool get hasContact => sosContactPhone.isNotEmpty;

  /// Starts sharing. Returns false (with [lastError] set) when it could not
  /// start: no SOS contact, no GPS fix, or the cloud event was rejected.
  Future<bool> start({
    required String reason,
    String? destinationName,
    String travelerName = 'Traveler',
  }) async {
    if (_active) return true;
    _lastError = null;
    _reason = reason;
    _destinationName = destinationName;
    _travelerName = travelerName;

    if (!hasContact) {
      _lastError = 'no-contact';
      notifyListeners();
      return false;
    }

    // Resolve a first real position before anything else — a share without
    // any location is useless.
    final Position? pos = await _fix();
    if (pos == null) {
      _lastError = 'no-location';
      notifyListeners();
      return false;
    }

    final String uid = currentUid();
    final String who = sosContactName.isNotEmpty ? sosContactName : 'your SOS contact';

    // Create the cloud event; if the cloud is unreachable, still share by
    // SMS — safety must never depend on connectivity.
    String eventId;
    try {
      eventId = await emergencyRepository.create(
        uid: uid,
        name: travelerName,
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyMeters: pos.accuracy,
        kind: 'live_share',
        reason: _reason,
      );
    } catch (e) {
      eventId = 'local-${DateTime.now().millisecondsSinceEpoch}';
      _lastError = 'cloud-unavailable';
    }

    _eventId = eventId;
    _active = true;
    _startedAt = DateTime.now();
    _lastPosition = pos;
    _cloudUpdates = 0;
    _smsSent = 0;
    _smsEnabled = await smsService.hasSendSmsPermission();

    // First SMS goes out immediately (best effort).
    await _sendSmsUpdate();

    _cloudTimer = Timer.periodic(cloudRefreshInterval, (_) => _pushCloud());
    _smsTimer = Timer.periodic(smsInterval, (_) => _sendSmsUpdate());

    notificationService.show(
      id: 4711001,
      title: '📍 Live location sharing is ON',
      body: 'Your location is being shared with $who'
          '${_smsEnabled ? ' by SMS' : ''}. Open Tourism to stop sharing.',
      channel: 'emergency',
      important: true,
      payload: 'live-share:$eventId',
    );

    notifyListeners();
    return true;
  }

  /// Stops sharing and (best-effort) marks the cloud event cancelled.
  Future<void> stop({String status = 'cancelled'}) async {
    if (!_active) return;
    final String? eventId = _eventId;
    _cloudTimer?.cancel();
    _cloudTimer = null;
    _smsTimer?.cancel();
    _smsTimer = null;
    _active = false;
    notifyListeners();
    if (eventId != null && !eventId.startsWith('local-')) {
      try {
        await emergencyRepository.updateStatus(eventId, status);
      } catch (_) {
        // Best effort — the timers are already stopped.
      }
    }
    final String who = sosContactName.isNotEmpty ? sosContactName : 'your SOS contact';
    notificationService.show(
      id: 4711002,
      title: 'Live location sharing stopped',
      body: 'Your location is no longer being shared with $who.',
      channel: 'emergency',
    );
    _eventId = null;
    notifyListeners();
  }

  /// Called right after the user grants the SMS permission from the banner:
  /// re-checks the permission and pushes an SMS update immediately instead
  /// of waiting for the next 5-minute tick.
  Future<void> enableSmsNow() async {
    if (!_active) return;
    _smsEnabled = await smsService.hasSendSmsPermission();
    notifyListeners();
    if (_smsEnabled) await _sendSmsUpdate();
  }

  /// One-tap manual SMS with the current location (works even when the
  /// continuous share is off).
  Future<bool> sendManualSmsNow() async {
    if (!hasContact) return false;
    if (!await smsService.hasSendSmsPermission()) return false;
    final int before = _smsSent;
    await _sendSmsUpdate();
    return _smsSent > before;
  }

  Future<Position?> _fix() async {
    try {
      return await locationService.currentPosition();
    } catch (_) {
      try {
        return await locationService.lastKnown();
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _pushCloud() async {
    if (!_active) return;
    final String? eventId = _eventId;
    if (eventId == null || eventId.startsWith('local-')) return;
    final Position? pos = await _fix();
    if (pos == null) return;
    _lastPosition = pos;
    try {
      await emergencyRepository.updateLiveLocation(
        eventId,
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyMeters: pos.accuracy,
      );
      _cloudUpdates++;
      _lastError = null;
    } catch (_) {
      // Transient (offline / rules) — keep the local state and retry on the
      // next tick; SMS keeps the contact informed regardless.
      _lastError = 'cloud-unavailable';
    }
    notifyListeners();
  }

  Future<void> _sendSmsUpdate() async {
    if (!_active || !hasContact) return;
    if (!_smsEnabled) {
      _smsEnabled = await smsService.hasSendSmsPermission();
      if (!_smsEnabled) return;
    }
    // Prefer a fresh fix; fall back to the last known one.
    final Position? pos = (await _fix()) ?? _lastPosition;
    if (pos == null) return;
    _lastPosition = pos;
    final String text = SosMessages.buildLiveShareText(
      travelerName: _travelerName,
      position: pos,
      destinationName: _destinationName,
    );
    final bool ok = await smsService.sendSms(sosContactPhone, text);
    if (ok) {
      _smsSent++;
      _lastSmsAt = DateTime.now();
      _lastError = null;
    }
    notifyListeners();
  }

  /// Anonymous usage note persisted in the notification history (best effort).
  void recordHistoryEvent(String title, String body) {
    try {
      final String uid = currentUid();
      notificationsRepository
          .add(
            uid: uid,
            title: title,
            body: body,
            type: 'emergency',
            payload: <String, dynamic>{
              if (_eventId != null) 'emergencyId': _eventId!,
            },
          )
          .catchError((Object _) => '');
    } catch (_) {}
  }

  @override
  void dispose() {
    _cloudTimer?.cancel();
    _smsTimer?.cancel();
    super.dispose();
  }
}
