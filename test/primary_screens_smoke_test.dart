import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tourism/core/services/location_service.dart';
import 'package:tourism/core/state/app_container.dart';
import 'package:tourism/core/theme/app_theme.dart';
import 'package:tourism/data/models/safety_zone.dart';
import 'package:tourism/data/repositories/auth_repository.dart';
import 'package:tourism/data/repositories/zones_repository.dart';
import 'package:tourism/features/profile/screens/profile_screen.dart';
import 'package:tourism/features/safety/screens/safety_screen.dart';
import 'package:tourism/features/vehicle/screens/vehicle_screen.dart';
import 'package:tourism/features/weather/screens/weather_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> verifyScreen(
    WidgetTester tester,
    Widget screen,
    String expectedText,
  ) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AppScope(
        container: _TestAppContainer(),
        child: MaterialApp(theme: AppTheme.light(), home: screen),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text(expectedText), findsWidgets);
  }

  testWidgets('Safety screen completes startup without framework exceptions',
      (WidgetTester tester) async {
    await verifyScreen(tester, const SafetyScreen(), 'Safe route');
  });

  testWidgets('Vehicle screen completes startup without framework exceptions',
      (WidgetTester tester) async {
    await verifyScreen(tester, const VehicleScreen(), 'Fuel log');
  });

  testWidgets('Weather screen completes startup without framework exceptions',
      (WidgetTester tester) async {
    await verifyScreen(tester, const WeatherScreen(), 'Weather');
  });

  testWidgets('Profile screen completes startup without framework exceptions',
      (WidgetTester tester) async {
    await verifyScreen(tester, const ProfileScreen(), 'Settings');
  });
}

class _TestAppContainer extends AppContainer {
  _TestAppContainer() : super(firebaseReady: false, app: null);

  final _FakeAuthRepository _auth = _FakeAuthRepository();
  final _FakeZonesRepository _zones = _FakeZonesRepository();
  final _FakeLocationService _location = _FakeLocationService();

  @override
  AuthRepository get authRepository => _auth;

  @override
  ZonesRepository get zonesRepository => _zones;

  @override
  LocationService get locationService => _location;
}

class _FakeAuthRepository implements AuthRepository {
  @override
  User? get currentUser => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeZonesRepository implements ZonesRepository {
  @override
  Stream<List<SafetyZone>> watchAll() =>
      Stream<List<SafetyZone>>.value(const <SafetyZone>[]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocationService implements LocationService {
  @override
  Future<Position?> currentPosition({
    Duration timeout = const Duration(seconds: 8),
  }) =>
      Future<Position?>.value(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
