import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Home SOS action labels do not throw ParentData errors',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.campaign),
                  // Reproduce the current HomeScreen layout before replacing
                  // it with a shared production widget.
                  label: const Flexible(
                    child: Text('Report incident', overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.qr_code_2),
                  label: const Flexible(
                    child: Text('Emergency ID', overflow: TextOverflow.ellipsis),
                  ),
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
  });
}
