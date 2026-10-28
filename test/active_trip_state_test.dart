import 'package:flutter_test/flutter_test.dart';
import 'package:yatrawise/core/state/active_trip.dart';

void main() {
  test('ending navigation removes all resumable destination data', () {
    final ActiveTripState state = ActiveTripState();
    state.begin(
      lat: 26.76003,
      lng: 80.98967,
      name: 'Dropped pin',
      mode: 'walk',
    );

    expect(state.hasDestination, isTrue);
    expect(state.route, contains('/trip/live'));

    state.end();

    expect(state.active, isFalse);
    expect(state.hasDestination, isFalse);
    expect(state.lat, isNull);
    expect(state.lng, isNull);
    expect(state.name, isEmpty);
    expect(state.startedAt, isNull);
    expect(state.mode, 'car');
  });

  test('ending an already empty navigation is safe', () {
    final ActiveTripState state = ActiveTripState();
    expect(state.end, returnsNormally);
    expect(state.hasDestination, isFalse);
  });
}
