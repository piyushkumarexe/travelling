import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tourism/features/home/screens/home_screen.dart';

void main() {
  testWidgets('Home SOS action labels do not throw ParentData errors',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              Expanded(
                child: HomeSosActionButton(
                  icon: Icons.campaign,
                  label: 'Report incident',
                  onPressed: () {},
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: HomeSosActionButton(
                  icon: Icons.qr_code_2,
                  label: 'Emergency ID',
                  onPressed: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Report incident'), findsOneWidget);
    expect(find.text('Emergency ID'), findsOneWidget);
    // Flutter's OutlinedButton.icon supplies this single Flexible. A second
    // Flexible in the label would compete with it and crash the screen.
    expect(
      find.descendant(
        of: find.byType(OutlinedButton),
        matching: find.byType(Flexible),
      ),
      findsNWidgets(2),
    );
  });
}
