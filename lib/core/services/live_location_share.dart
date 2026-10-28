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
  bool _whatsappAutoOpened = false;
  String _lastSmsText = '';

  Timer? _cloudTimer;
  Timer? _smsTimer;
  int _generation = 0;
  bool _starting = false;

  bool get active => _active;
  String? get destinationName => _destinationName;
  Position? get lastPosition => _lastPosition;
  DateTime? get startedAt => _startedAt;
  DateTime? get lastSmsAt => _lastSmsAt;
  /// Number handed to the radio; not the number delivered.
  int get smsQueued => _smsSent;
  int get smsSent => _smsSent;
  int get cloudUpdates => _cloudUpdates;
  String? get lastError => _lastError;
  String get lastSmsText => _lastSmsText;
  bool get whatsappAutoOpened => _whatsappAutoOpened;

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
    if (_starting) {
      _lastError = 'start-in-progress';
      return false;
    }
    _starting = true;
    final int generation = ++_generation;
    _lastError = null;
    _reason = reason;
    _destinationName = destinationName;
    _travelerName = travelerName;

    try {
      if (!hasContact) {
        _lastError = 'no-contact';
        notifyListeners();
        return false;
      }
      final Position? pos = await _fix();
      if (generation != _generation) return false;
      if (pos == null) {
        _lastError = 'no-location';
        notifyListeners();
        return false;
      }

      final String uid = currentUid();
      String? eventId;
      if (uid.isEmpty) {
        _lastError = 'cloud-unavailable';
      } else {
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
        } catch (_) {
          _lastError = 'cloud-unavailable';
        }
      }
      if (generation != _generation) {
        if (eventId != null) {
          try {
            await emergencyRepository.updateStatus(eventId, 'cancelled');
          } catch (_) {}
        }
        return false;
      }

      _eventId = eventId;
      _active = true;
      _startedAt = DateTime.now();
      _lastPosition = pos;
      _cloudUpdates = 0;
      _smsSent = 0;
      _lastSmsAt = null;
      _whatsappAutoOpened = false;
      _smsEnabled = await smsService.hasSendSmsPermission();
      if (generation != _generation || !_active) return false;
      notifyListeners();

      await _sendSmsUpdate();
      if (generation != _generation || !_active) return false;

      unawaited(_maybeAutoWhatsapp());
      _cloudTimer = Timer.periodic(cloudRefreshInterval, (_) => _pushCloud());
      _smsTimer = Timer.periodic(smsInterval, (_) => _sendSmsUpdate());

      final String who = sosContactName.isNotEmpty
          ? sosContactName
          : 'your SOS contact';
      final bool cloudAvailable = _eventId != null;
      notificationService.show(
        id: 4711001,
        title: 'Live location updates are ON',
        body: '${_smsEnabled ? 'SMS updates are being attempted to $who; delivery is not confirmed.' : 'SMS permission is off; use the banner to enable it.'} '
            '${cloudAvailable ? 'Cloud updates are active.' : 'Cloud updates are currently unavailable.'}',
        channel: 'emergency',
        important: true,
        payload: eventId == null ? 'live-share:local' : 'live-share:$eventId',
      );
      notifyListeners();
      return true;
    } finally {
      if (generation == _generation) _starting = false;
    }
  }

  /// Stops sharing and (best-effort) marks the cloud event cancelled.
  Future<void> stop({String status = 'cancelled'}) async {
    ++_generation; // Invalidate every in-flight start/update immediately.
    _starting = false;
    final String? eventId = _eventId;
    final bool wasActive = _active;
    _cloudTimer?.cancel();
    _cloudTimer = null;
    _smsTimer?.cancel();
    _smsTimer = null;
    _active = false;
    _eventId = null;
    _whatsappAutoOpened = false;
    notifyListeners();
    if (eventId != null) {
      try {
        await emergencyRepository.updateStatus(eventId, status);
      } catch (_) {}
    }
    if (wasActive) {
      notificationService.show(
        id: 4711002,
        title: 'Live location updates stopped',
        body: 'Automatic location updates stopped. Messages already handed '
            'to the radio cannot be recalled.',
        channel: 'emergency',
      );
    }
    notifyListeners();
  }

  /// Called right after the user grants the SMS permission from the banner:
  /// re-checks the permission and pushes an SMS update immediately instead
  /// of waiting for the next 5-minute tick.
  Future<void> enableSmsNow() async {
    if (!_active) return;
    final int generation = _generation;
    _smsEnabled = await smsService.hasSendSmsPermission();
    if (generation != _generation || !_active) return;
    notifyListeners();
    if (_smsEnabled) await _sendSmsUpdate();
  }

  /// One-tap manual SMS. True means radio hand-off, not delivery.
  Future<bool> sendManualSmsNow() async {
    if (!hasContact) return false;
    if (!await smsService.hasSendSmsPermission()) return false;
    final int before = _smsSent;
    await _sendSmsUpdate();
    return _smsSent > before;
  }

  /// Opens the WhatsApp chat with the SOS contact pre-filled with the
  /// latest location — automatically at share start (when online), and
  /// on demand from the banner / trip card.
  Future<void> _maybeAutoWhatsapp() async {
    if (!_active || _whatsappAutoOpened || !hasContact) return;
    final int generation = _generation;
    if (!await smsService.hasInternet()) return;
    if (generation != _generation || !_active) return;
    _whatsappAutoOpened = true;
    notifyListeners();
    await shareWhatsAppNow(expectedGeneration: generation);
  }

  /// One-tap: opens WhatsApp with the current location message pre-filled.
  /// [expectedGeneration] prevents an automatic open after sharing stops.
  Future<bool> shareWhatsAppNow({int? expectedGeneration}) async {
    if (!hasContact) return false;
    final Position? pos = (await _fix()) ?? _lastPosition;
    if (pos == null ||
        (expectedGeneration != null &&
            (expectedGeneration != _generation || !_active))) {
      return false;
    }
    _lastPosition = pos;
    final String text = SosMessages.buildLiveShareText(
      travelerName: _travelerName,
      position: pos,
      destinationName: _destinationName,
    );
    _lastSmsText = text;
    return smsService.openWhatsApp(sosContactPhone, text);
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
    final int generation = _generation;
    final Position? pos = await _fix();
    if (generation != _generation || !_active || pos == null) return;
    _lastPosition = pos;
    final String uid = currentUid();
    if (uid.isEmpty) {
      _lastError = 'cloud-unavailable';
      notifyListeners();
      return;
    }
    String? eventId = _eventId;
    bool created = false;
    try {
      if (eventId == null) {
        eventId = await emergencyRepository.create(
          uid: uid,
          name: _travelerName,
          lat: pos.latitude,
          lng: pos.longitude,
          accuracyMeters: pos.accuracy,
          kind: 'live_share',
          reason: _reason,
        );
        created = true;
      } else {
        await emergencyRepository.updateLiveLocation(
          eventId,
          lat: pos.latitude,
          lng: pos.longitude,
          accuracyMeters: pos.accuracy,
        );
      }
      if (generation != _generation || !_active) {
        if (created) {
          try {
            await emergencyRepository.updateStatus(eventId, 'cancelled');
          } catch (_) {}
        }
        return;
      }
      _eventId = eventId;
      _cloudUpdates++;
      _lastError = null;
    } catch (_) {
      if (generation == _generation && _active) {
        _lastError = 'cloud-unavailable';
      }
    }
    if (generation == _generation) notifyListeners();
  }

  Future<void> _sendSmsUpdate() async {
    if (!_active || !hasContact) return;
    final int generation = _generation;
    if (!_smsEnabled) {
      _smsEnabled = await smsService.hasSendSmsPermission();
      if (generation != _generation || !_active) return;
      if (!_smsEnabled) {
        notifyListeners();
        return;
      }
    }
    final Position? pos = (await _fix()) ?? _lastPosition;
    if (generation != _generation || !_active || pos == null) return;
    _lastPosition = pos;
    final String text = SosMessages.buildLiveShareText(
      travelerName: _travelerName,
      position: pos,
      destinationName: _destinationName,
    );
    _lastSmsText = text;
    final bool queued = await smsService.sendSms(sosContactPhone, text);
    if (generation != _generation || !_active) return;
    if (queued) {
      _smsSent++; // Radio hand-off only; this is NOT a delivery receipt.
      _lastSmsAt = DateTime.now();
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
    ++_generation;
    _active = false;
    _cloudTimer?.cancel();
    _smsTimer?.cancel();
    super.dispose();
  }
}
