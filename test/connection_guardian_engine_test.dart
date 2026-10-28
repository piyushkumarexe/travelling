import 'package:flutter_test/flutter_test.dart';
import 'package:tourism/features/connection_guardian/connection_guardian_engine.dart';

void main() {
  final DateTime arrival = DateTime(2026, 10, 2, 10);

  test('safe train connection keeps a positive explained margin', () {
    final ConnectionAssessment result = ConnectionGuardianEngine.assess(
      scheduledArrival: arrival,
      nextDeparture: arrival.add(const Duration(minutes: 90)),
      incomingMode: ConnectionMode.train,
      outgoingMode: ConnectionMode.train,
    );

    expect(result.risk, ConnectionRisk.safe);
    expect(result.requiredMinutes, 25);
    expect(result.marginMinutes, 65);
  });

  test('known delay is subtracted from available transfer time', () {
    final ConnectionAssessment result = ConnectionGuardianEngine.assess(
      scheduledArrival: arrival,
      nextDeparture: arrival.add(const Duration(minutes: 100)),
      incomingMode: ConnectionMode.train,
      outgoingMode: ConnectionMode.flight,
      knownDelayMinutes: 35,
    );

    expect(result.availableMinutes, 65);
    expect(result.requiredMinutes, 60);
    expect(result.risk, ConnectionRisk.tight);
  });

  test('international baggage and mobility conditions each add buffer', () {
    final ConnectionAssessment result = ConnectionGuardianEngine.assess(
      scheduledArrival: arrival,
      nextDeparture: arrival.add(const Duration(hours: 4)),
      incomingMode: ConnectionMode.flight,
      outgoingMode: ConnectionMode.flight,
      terminalChange: true,
      baggageRecheck: true,
      internationalTransfer: true,
      mobilityAssistance: true,
    );

    expect(result.requiredMinutes, 180);
    expect(result.reasons, hasLength(5));
    expect(result.risk, ConnectionRisk.safe);
  });

  test('arrival after departure is classified as missed', () {
    final ConnectionAssessment result = ConnectionGuardianEngine.assess(
      scheduledArrival: arrival,
      nextDeparture: arrival.add(const Duration(minutes: 40)),
      incomingMode: ConnectionMode.bus,
      outgoingMode: ConnectionMode.train,
      knownDelayMinutes: 60,
    );

    expect(result.availableMinutes, -20);
    expect(result.risk, ConnectionRisk.missed);
    expect(result.actions.join(' '), contains('official provider'));
  });
}
