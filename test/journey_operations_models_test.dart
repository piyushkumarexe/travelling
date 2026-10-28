import 'package:flutter_test/flutter_test.dart';
import 'package:yatrawise/features/operations/journey_operations_models.dart';

void main() {
  test('exposes thirty-seven distinct working journey tools', () {
    expect(journeyToolDefinitions, hasLength(37));
    expect(
      journeyToolDefinitions
          .map((JourneyToolDefinition definition) => definition.kind)
          .toSet(),
      hasLength(37),
    );
    for (final JourneyToolDefinition definition in journeyToolDefinitions) {
      expect(definition.title, isNotEmpty);
      expect(definition.primaryLabel, isNotEmpty);
      expect(definitionFor(definition.kind), same(definition));
    }
  });

  test('operation survives a Firestore map round trip', () {
    final JourneyOperation original = JourneyOperation(
      id: 'item-1',
      userId: 'user-1',
      kind: JourneyToolKind.accessibility,
      title: 'Wheelchair assistance',
      detail: 'Requested from the airline',
      extra: 'Reference ABC123',
      completed: true,
      createdAt: DateTime(2026, 9, 25, 10),
      updatedAt: DateTime(2026, 9, 25, 11),
    );

    final JourneyOperation restored =
        JourneyOperation.fromFirestore(original.toFirestore());
    expect(restored.id, original.id);
    expect(restored.userId, original.userId);
    expect(restored.kind, original.kind);
    expect(restored.title, original.title);
    expect(restored.detail, original.detail);
    expect(restored.extra, original.extra);
    expect(restored.completed, isTrue);
    expect(restored.createdAt, original.createdAt);
    expect(restored.updatedAt, original.updatedAt);
  });

  test('unknown persisted kind falls back safely to task board', () {
    final JourneyOperation restored = JourneyOperation.fromFirestore(
      <String, dynamic>{
        'id': 'legacy',
        'userId': 'user-1',
        'kind': 'removedKind',
        'title': 'Legacy task',
        'detail': '',
        'extra': '',
        'completed': false,
        'createdAt': 0,
        'updatedAt': 0,
      },
    );
    expect(restored.kind, JourneyToolKind.taskBoard);
  });
}
