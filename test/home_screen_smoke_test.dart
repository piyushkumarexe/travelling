import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tourism/core/services/location_service.dart';
import 'package:tourism/core/state/app_container.dart';
import 'package:tourism/core/theme/app_theme.dart';
import 'package:tourism/data/models/safety_zone.dart';
import 'package:tourism/data/repositories/auth_repository.dart';
import 'package:tourism/data/repositories/zones_repository.dart';
import 'package:tourism/features/autopilot/autopilot_models.dart';
import 'package:tourism/features/autopilot/autopilot_service.dart';
import 'package:tourism/features/home/screens/home_screen.dart';

void main() {
  testWidgets('complete Home dashboard builds without framework exceptions',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _TestAppContainer container = _TestAppContainer();
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('Emergency? Tap SOS'), findsOneWidget);
    expect(find.text('Travel tools'), findsOneWidget);
    expect(find.text('Quick actions'), findsOneWidget);
    expect(find.text('Nearby attractions'), findsOneWidget);
  });
}

class _TestAppContainer extends AppContainer {
  _TestAppContainer() : super(firebaseReady: false, app: null);

  final _FakeAuthRepository _auth = _FakeAuthRepository();
  final _FakeZonesRepository _zones = _FakeZonesRepository();
  final _FakeLocationService _location = _FakeLocationService();
  final _FakeAutopilotService _autopilot = _FakeAutopilotService();

  @override
  AuthRepository get authRepository => _auth;

  @override
  ZonesRepository get zonesRepository => _zones;

  @override
  LocationService get locationService => _location;

  @override
  AutopilotService get autopilotService => _autopilot;
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

class _FakeAutopilotService implements AutopilotService {
  @override
  AutopilotSession? get session => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
