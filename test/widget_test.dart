import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roamio/core/theme/app_theme.dart';
import 'package:roamio/core/widgets/app_button.dart';
import 'package:roamio/core/widgets/app_loader.dart';
import 'package:roamio/core/widgets/state_views.dart';

void main() {
  Widget pumpApp(Widget child) {
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('PrimaryButton shows label and fires onPressed',
      (WidgetTester tester) async {
    bool tapped = false;
    await tester.pumpWidget(pumpApp(
      PrimaryButton(
        label: 'Save trip',
        icon: Icons.save,
        onPressed: () => tapped = true,
      ),
    ));

    expect(find.text('Save trip'), findsOneWidget);
    expect(tapped, isFalse);
    await tester.tap(find.text('Save trip'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('PrimaryButton hides label when loading',
      (WidgetTester tester) async {
    await tester.pumpWidget(pumpApp(
      const PrimaryButton(label: 'Working', loading: true),
    ));
    expect(find.text('Working'), findsNothing);
    expect(find.byType(TravelBallLoader), findsOneWidget);
  });

  testWidgets('EmptyState renders title and action',
      (WidgetTester tester) async {
    bool action = false;
    await tester.pumpWidget(pumpApp(
      EmptyState(
        icon: Icons.search,
        title: 'Nothing here',
        message: 'Try again later.',
        actionLabel: 'Go',
        onAction: () => action = true,
      ),
    ));
    expect(find.text('Nothing here'), findsOneWidget);
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(action, isTrue);
  });

  testWidgets('ErrorState shows retry', (WidgetTester tester) async {
    bool retried = false;
    await tester.pumpWidget(pumpApp(
      ErrorState(
        message: 'Network down',
        onRetry: () => retried = true,
      ),
    ));
    expect(find.text('Network down'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retried, isTrue);
  });
}
