import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:yatrawise/core/utils/sos_messages.dart';

Position _pos(double lat, double lng, {double accuracy = 12}) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  group('SosMessages.buildEmergencyText', () {
    test('includes coordinates, accuracy and a map link', () {
      final String text = SosMessages.buildEmergencyText(
        travelerName: 'Piyush',
        position: _pos(26.8467, 80.9462),
      );
      expect(text, contains('Piyush'));
      expect(text, contains('26.846700'));
      expect(text, contains('80.946200'));
      expect(text, contains('±12 m'));
      expect(text, contains('https://maps.google.com/?q=26.846700,80.946200'));
      expect(text, startsWith('EMERGENCY'));
    });

    test('falls back to "I" when the traveler name is blank', () {
      final String text = SosMessages.buildEmergencyText(
        travelerName: '   ',
        position: _pos(0, 0),
      );
      expect(text, contains('I need help'));
    });
  });

  group('SosMessages.buildPowerOffText', () {
    test('mentions the switch-off and carries the coordinates', () {
      final String text = SosMessages.buildPowerOffText(
        travelerName: 'Ravi',
        lat: 28.61,
        lng: 77.21,
      );
      expect(text, contains("Ravi's phone is switching OFF"));
      expect(text, contains('28.61,77.21'));
      expect(text, contains('https://maps.google.com/?q=28.61,77.21'));
    });

    test('blank name still reads naturally', () {
      final String text = SosMessages.buildPowerOffText(
        travelerName: '',
        lat: 1,
        lng: 2,
      );
      expect(text, contains('My phone is switching OFF'));
    });
  });

  group('SosMessages.buildLiveShareText', () {
    test('says LIVE LOCATION and names the destination', () {
      final String text = SosMessages.buildLiveShareText(
        travelerName: 'Aditi',
        position: _pos(19.076, 72.8777),
        destinationName: 'Marine Drive',
      );
      expect(text, startsWith('LIVE LOCATION'));
      expect(text, contains('Aditi'));
      expect(text, contains('navigating to Marine Drive'));
      expect(text, contains('19.076000'));
      expect(text, contains('https://maps.google.com/?q=19.076000,72.877700'));
    });

    test('works without a destination', () {
      final String text = SosMessages.buildLiveShareText(
        travelerName: 'Sam',
        position: _pos(10, 20),
      );
      expect(text, contains('navigating in Tourism'));
    });
  });
}
