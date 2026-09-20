// 🆘 Offline Emergency Location SMS.
//
// Works with NO internet: the location comes from the device's GPS (geolocator
// — pure satellite, no network needed) and the message is sent through the
// native SmsManager (cellular). The ONLY requirement is SIM/cellular signal,
// and the UI states that honestly.
//
// Honesty rules enforced here:
//  - Fresh GPS fix   → "Current location (GPS)"
//  - No fix in time  → cached last-known location, labelled "Last known"
//  - No location at all → NO coordinates are invented; the attempt reports
//    the typed failure instead.
//  - "Sent" is reported ONLY when Android's radio accepted the message
//    (sent-intent callback). "Delivered" only on a real delivery report.
//  - No Firebase, no HTTP, no WhatsApp anywhere in this path.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'location_service.dart';
import 'settings_service.dart';

/// Lifecycle of one emergency SMS attempt, persisted locally.
enum EmergencySmsStatus {
  idle('Not attempted yet'),
  acquiringLocation('Getting location…'),
  noLocation('No location available'),
  permissionDenied('SMS permission denied'),
  noSim('No SIM card'),
  noCellular('No cellular service'),
  queued('Handed to the radio…'),
  // The phone's security layer blocked the direct SmsManager send, so the
  // device's own SMS app was opened with the FULL message pre-filled. The
  // SMS app holds the system's SMS privileges — one tap of Send in that
  // app delivers it. This is an honest hand-off, not a "sent" claim.
  smsAppOpened('Opened your SMS app — press Send there'),
  sent('Sent (radio accepted)'),
  delivered('Delivered (carrier confirmed)'),
  failed('Failed');

  const EmergencySmsStatus(this.label);
  final String label;
}

class EmergencySmsResult {
  const EmergencySmsResult({
    required this.status,
    this.locationFresh = false,
    this.locationAge,
    this.accuracyMeters,
    this.detail = '',
  });

  final EmergencySmsStatus status;

  /// True only when the SMS carried a FRESH GPS fix (not cached).
  final bool locationFresh;

  /// Age of the used location (fresh or cached), when known.
  final Duration? locationAge;

  /// Location accuracy in meters, when the fix reported it.
  final double? accuracyMeters;

  final String detail;
}

class EmergencySmsService {
  EmergencySmsService({
    required LocationService location,
    required SettingsService settings,
  })  : _location = location,
        _settings = settings {
    _statusEvents = _statusChannel
        .receiveBroadcastStream()
        .map((dynamic e) => Map<String, dynamic>.from(e as Map));
  }

  static const MethodChannel _channel =
      MethodChannel('app.roamio.tourism/emergency_sms');
  static const EventChannel _statusChannel =
      EventChannel('app.roamio.tourism/emergency_sms_status');

  final LocationService _location;
  final SettingsService _settings;

  /// Stream of {ref, kind, ok, error} events from the native side.
  late final Stream<Map<String, dynamic>> _statusEvents;
  StreamSubscription<Map<String, dynamic>>? _sub;

  EmergencySmsStatus _lastStatus = EmergencySmsStatus.idle;
  EmergencySmsStatus get lastStatus => _lastStatus;

  /// Fires after every status change (sent / delivered / failed …).
  final StreamController<EmergencySmsStatus> _statusCtrl =
      StreamController<EmergencySmsStatus>.broadcast();
  Stream<EmergencySmsStatus> get statusStream => _statusCtrl.stream;

  Future<void> _setStatus(EmergencySmsStatus s) async {
    _lastStatus = s;
    _statusCtrl.add(s);
    await _settings.setOfflineEmergencyLastStatus(s.label);
  }

  // ---------------- capability checks (honest) ----------------

  Future<bool> hasSendPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasSendSms') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestSendPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestSendSms') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// "ready" | "no_sim" | "unknown"
  Future<String> simState() async {
    try {
      return await _channel.invokeMethod<String>('simState') ?? 'unknown';
    } on MissingPluginException {
      return 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  /// "service" | "no_service" | "emergency_only" | "no_sim" | "unknown"
  Future<String> cellularState() async {
    try {
      return await _channel.invokeMethod<String>('cellularState') ?? 'unknown';
    } on MissingPluginException {
      return 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  // ---------------- the emergency path ----------------

  /// Builds the emergency text. [fresh] decides the fresh/last-known label —
  /// never claim "current" for a cached fix.
  static String buildMessage({
    required String travelerName,
    required Position pos,
    required bool fresh,
  }) {
    final DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final String ts =
        '${now.day}/${now.month}/${now.year} ${two(now.hour)}:${two(now.minute)}';
    final int ageMin =
        now.difference(pos.timestamp.toLocal()).inMinutes.clamp(0, 100000);
    final StringBuffer b = StringBuffer()
      ..write('EMERGENCY: ')
      ..write(travelerName.isEmpty ? 'A traveler' : travelerName)
      ..write(fresh ? ' — CURRENT location (GPS)' : ' — LAST KNOWN location')
      ..write(' https://maps.google.com/?q=')
      ..write(pos.latitude.toStringAsFixed(5))
      ..write(',')
      ..write(pos.longitude.toStringAsFixed(5))
      ..write(' · coordinates ')
      ..write(pos.latitude.toStringAsFixed(5))
      ..write(',')
      ..write(pos.longitude.toStringAsFixed(5))
      ..write(' · sent $ts');
    if (pos.accuracy > 0) {
      b.write(' · accuracy ±${pos.accuracy.toStringAsFixed(0)} m');
    }
    if (!fresh) b.write(' · fix $ageMin min old');
    return b.toString();
  }

  /// Sends the emergency SMS through the OFFLINE path (GPS + cellular only).
  ///
  /// Order: fresh GPS (bounded wait) → cached last-known → typed failure.
  Future<EmergencySmsResult> sendOfflineEmergencySms({
    String travelerName = '',
    Duration gpsTimeout = const Duration(seconds: 12),
  }) async {
    // 1) Permission first — nothing can be attempted without it.
    if (!await hasSendPermission()) {
      await _setStatus(EmergencySmsStatus.permissionDenied);
      return const EmergencySmsResult(
          status: EmergencySmsStatus.permissionDenied,
          detail: 'SEND_SMS permission is not granted.');
    }

    // 2) SIM / cellular honesty up-front (best-effort; some OEMs report
    //    'unknown' — then we still TRY and let the radio callback decide).
    final String cell = await cellularState();
    if (cell == 'no_sim') {
      await _setStatus(EmergencySmsStatus.noSim);
      return const EmergencySmsResult(
          status: EmergencySmsStatus.noSim,
          detail: 'No SIM card detected — SMS cannot be sent.');
    }

    // 3) Location: bounded fresh-fix attempt, then the cached last-known
    //    fix (LocationService already persists it on-device). GPS itself
    //    needs no internet — only satellite signal. refreshPosition is the
    //    explicit ACCURACY path (never returns a stale cache): an emergency
    //    message must carry a real GPS fix, accepting the shortest
    //    available error within the bounded wait.
    await _setStatus(EmergencySmsStatus.acquiringLocation);
    Position? pos;
    bool fresh = false;
    try {
      pos = await _location.refreshPosition(timeout: gpsTimeout);
    } catch (_) {
      pos = null;
    }
    if (pos == null) {
      try {
        pos = await _location.lastKnown();
      } catch (_) {
        pos = null;
      }
    }
    if (pos == null) {
      await _setStatus(EmergencySmsStatus.noLocation);
      return const EmergencySmsResult(
          status: EmergencySmsStatus.noLocation,
          detail:
              'No GPS fix and no cached location — not sending made-up '
              'coordinates.');
    }
    // A fix is "fresh" only when it is newer than our own wait window plus
    // margin — otherwise it IS the cached last-known one and must be
    // labelled as such.
    fresh = DateTime.now()
        .difference(pos.timestamp.toLocal())
        .compareTo(const Duration(minutes: 2)) < 0;

    // 4) Tracked send through the radio with Android sent/delivery intents.
    final String ref =
        'ems${DateTime.now().millisecondsSinceEpoch}';
    final EmergencySmsResult result = await _trackedSend(
        ref: ref,
        phone: _settings.sosContactPhone,
        text: buildMessage(
            travelerName: travelerName, pos: pos, fresh: fresh));
    return EmergencySmsResult(
      status: result.status,
      locationFresh: fresh,
      locationAge: DateTime.now().difference(pos.timestamp.toLocal()),
      accuracyMeters: pos.accuracy > 0 ? pos.accuracy : null,
      detail: result.detail,
    );
  }

  Future<EmergencySmsResult> _trackedSend({
    required String ref,
    required String phone,
    required String text,
  }) async {
    if (phone.trim().isEmpty) {
      await _setStatus(EmergencySmsStatus.failed);
      return const EmergencySmsResult(
          status: EmergencySmsStatus.failed,
          detail: 'No SOS contact configured.');
    }

    final Completer<EmergencySmsResult> done =
        Completer<EmergencySmsResult>();
    unawaited(_sub?.cancel());
    _sub = _statusEvents.listen((Map<String, dynamic> e) {
      if (e['ref'] != ref || done.isCompleted) return;
      final String kind = e['kind'] as String? ?? '';
      final bool ok = e['ok'] as bool? ?? false;
      final String? error = e['error'] as String?;
      if (kind == 'sent') {
        if (ok) {
          unawaited(_setStatus(EmergencySmsStatus.sent));
          done.complete(EmergencySmsResult(
              status: EmergencySmsStatus.sent,
              detail: 'Android accepted the message for sending.'));
        } else {
          unawaited(_setStatus(EmergencySmsStatus.failed));
          done.complete(EmergencySmsResult(
              status: EmergencySmsStatus.failed,
              detail: error == 'no_service'
                  ? 'No cellular service — the radio rejected the SMS.'
                  : 'The radio rejected the SMS (${error ?? 'generic'}).'));
        }
      } else if (kind == 'delivery' && ok) {
        // Delivery often arrives after the sent callback — always persist
        // the upgrade; only complete the UI result if nothing reported yet.
        unawaited(_setStatus(EmergencySmsStatus.delivered));
        if (!done.isCompleted) {
          done.complete(const EmergencySmsResult(
              status: EmergencySmsStatus.delivered,
              detail: 'Carrier confirmed delivery.'));
        }
      }
    });

    // Native returns "queued" (radio hand-off, callbacks follow) or
    // "composer" (direct sends blocked by the phone's security layer — the
    // device's SMS app was opened with the message pre-filled instead).
    String outcome = '';
    try {
      outcome = await _channel.invokeMethod<String>('sendSmsTracked',
              <String, dynamic>{'ref': ref, 'to': phone, 'text': text}) ??
          '';
    } on PlatformException catch (e) {
      if (e.code == 'permission') {
        await _setStatus(EmergencySmsStatus.permissionDenied);
        return const EmergencySmsResult(
            status: EmergencySmsStatus.permissionDenied,
            detail: 'SEND_SMS permission is not granted.');
      }
      if (e.code == 'send_failed') {
        final String reason = e.message ?? 'unknown OS reason';
        final bool securityBlocked = reason.contains('SecurityException');
        await _setStatus(EmergencySmsStatus.failed);
        return EmergencySmsResult(
            status: EmergencySmsStatus.failed,
            detail: securityBlocked
                ? 'Blocked by your phone\'s security layer ($reason) AND '
                    'no SMS app could be opened to pre-fill the message. '
                    'The SMS permission IS granted at the Android level — '
                    'this is the OEM layer: on Xiaomi/MIUI enable Settings '
                    '→ Apps → this app → Permissions → SMS (send) = Allow '
                    'AND Security app → Permissions → SMS permissions → '
                    'this app = Allow, then force-stop this app and test '
                    'again. We tried every SmsManager variant before '
                    'showing this.'
                : 'Android refused the SMS send ($reason). This is the exact '
                    'OS/radio error.');
      }
      outcome = '';
    } catch (_) {
      outcome = '';
    }
    if (outcome == 'composer') {
      // Honest hand-off: the full message is pre-filled in the device's
      // own SMS app — the traveler presses Send there. Until then we do
      // NOT claim "sent".
      await _setStatus(EmergencySmsStatus.smsAppOpened);
      return const EmergencySmsResult(
          status: EmergencySmsStatus.smsAppOpened,
          detail:
              'Your phone blocks direct app SMS even though the SMS '
              'permission is granted (OEM security layer). Your SMS app '
              'was opened with the full message pre-filled — press Send '
              'there to deliver it. On Xiaomi/MIUI you can also allow: '
              'Settings → Apps → this app → Permissions → SMS (send), '
              'then force-stop this app and retest.');
    }
    if (outcome != 'queued') {
      await _setStatus(EmergencySmsStatus.noCellular);
      return const EmergencySmsResult(
          status: EmergencySmsStatus.noCellular,
          detail:
              'The message could not be handed to the radio (no service, '
              'no SIM) and no SMS app was available to pre-fill it.');
    }

    // Radio callbacks usually arrive within ~10 s; not guaranteed at all.
    try {
      return await done.future.timeout(const Duration(seconds: 15),
          onTimeout: () => const EmergencySmsResult(
              status: EmergencySmsStatus.queued,
              detail:
                  'Handed to the cellular radio — no confirmation arrived '
                  '(may still go out).'));
    } finally {
      unawaited(_sub?.cancel());
      _sub = null;
    }
  }

  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_statusCtrl.close());
  }
}
