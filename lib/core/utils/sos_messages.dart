import 'package:geolocator/geolocator.dart';

/// Pure builders for emergency location messages (SMS / WhatsApp).
/// Kept free of any I/O so they are directly unit-testable.
abstract final class SosMessages {
  /// The message sent when the traveler activates SOS.
  static String buildEmergencyText({
    required String travelerName,
    required Position position,
  }) {
    final String lat = position.latitude.toStringAsFixed(6);
    final String lng = position.longitude.toStringAsFixed(6);
    final String who = travelerName.trim().isEmpty ? 'I' : travelerName.trim();
    return 'EMERGENCY: $who need help (SOS activated in Tourism). '
        'My current location: $lat, $lng '
        '(±${position.accuracy.round()} m). '
        'Map: https://maps.google.com/?q=$lat,$lng';
  }

  /// The message sent when the traveler's phone is switching off
  /// (mirrors the native PowerOffReceiver text).
  static String buildPowerOffText({
    required String travelerName,
    required double lat,
    required double lng,
  }) {
    final String who = travelerName.trim().isEmpty ? 'My' : "${travelerName.trim()}'s";
    return 'EMERGENCY (Tourism): $who phone is switching OFF now. '
        'Last known location: $lat,$lng '
        'https://maps.google.com/?q=$lat,$lng';
  }

  /// The first message of a live location share.
  static String buildLiveShareText({
    required String travelerName,
    required Position position,
    String? destinationName,
  }) {
    final String lat = position.latitude.toStringAsFixed(6);
    final String lng = position.longitude.toStringAsFixed(6);
    final String who = travelerName.trim().isEmpty ? 'I' : travelerName.trim();
    final String what = destinationName == null
        ? 'am navigating in Tourism'
        : 'am navigating to $destinationName in Tourism';
    final Duration age = DateTime.now().difference(position.timestamp);
    final bool recent = !age.isNegative && age <= const Duration(minutes: 2);
    final String freshness = recent
        ? 'LIVE LOCATION'
        : 'LAST KNOWN LOCATION (${age.inMinutes.clamp(0, 100000)} min old)';
    return '$freshness: $who $what. '
        'Coordinates: $lat, $lng (±${position.accuracy.round()} m). '
        'Map: https://maps.google.com/?q=$lat,$lng';
  }
}
