import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Emergency SMS + WhatsApp messaging to the SOS contact.
///
/// - SMS goes through the native SmsManager (MethodChannel implemented in
///   MainActivity) so it works even with no mobile data — the only channel
///   that reaches the SOS contact during power-off or in remote areas.
/// - WhatsApp uses a wa.me deep link with the message pre-filled (WhatsApp
///   itself must send it; there is no keyless programmatic send). The chat
///   auto-opens when the internet is available so the traveler only has to
///   press send once.
class SmsService {
  static const MethodChannel _channel =
      MethodChannel('app.roamio.tourism/emergency_sms');

  /// Cheap connectivity probe (DNS). Best-effort: returns false on any
  /// failure, never throws.
  Future<bool> hasInternet() async {
    try {
      final List<InternetAddress> r = await InternetAddress.lookup(
        'www.google.com',
      ).timeout(const Duration(seconds: 4));
      return r.isNotEmpty && r.first.address.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// True when the SEND_SMS runtime permission is granted.
  Future<bool> hasSendSmsPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasSendSms') ?? false;
    } on MissingPluginException {
      return false; // not Android / tests
    } catch (_) {
      return false;
    }
  }

  /// Shows the Android SEND_SMS permission dialog when not granted yet.
  /// Re-check with [hasSendSmsPermission] after the user answers.
  /// Bounded by a 20 s safety timeout so a misbehaving OEM dialog can never
  /// leave a caller awaiting forever (the reported "app stops responding"
  /// class of bugs).
  Future<bool> ensureSendSmsPermission() async {
    if (await hasSendSmsPermission()) return true;
    try {
      return await _channel
          .invokeMethod<bool>('requestSendSms')
          .then<bool>((bool? granted) => granted ?? false)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () async => hasSendSmsPermission(),
          );
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Sends [text] to [phone] via the native SmsManager. Returns false when
  /// the permission is missing or the radio rejected the hand-off.
  Future<bool> sendSms(String phone, String text) async {
    final String clean = _cleanPhone(phone);
    if (clean.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'sendSms',
            <String, dynamic>{'to': clean, 'text': text},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Opens WhatsApp with [phone] and [text] pre-filled (user presses send).
  /// wa.me needs the number in international form without + or leading zeros.
  Future<bool> openWhatsApp(String phone, String text) async {
    final String clean = _cleanPhone(phone);
    final String digits = clean.replaceFirst('+', '').replaceAll(RegExp(r'\D'), '');
    final Uri uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
    if (await canLaunchUrl(uri)) {
      try {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// Opens the default SMS app with [phone] and [text] pre-filled as a
  /// fallback when direct SmsManager sending is unavailable (e.g. iOS).
  Future<bool> openSmsComposer(String phone, String text) async {
    final String clean = _cleanPhone(phone);
    final Uri uri = Uri.parse('sms:$clean?body=${Uri.encodeComponent(text)}');
    if (await canLaunchUrl(uri)) {
      try {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  static String _cleanPhone(String phone) => phone.trim();
}
