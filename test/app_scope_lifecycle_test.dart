import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tourism/core/state/app_container.dart';

void main() {
  testWidgets('AppScope services can be read during screen initState',
      (WidgetTester tester) async {
    final AppContainer container =
        AppContainer(firebaseReady: false, app: null);

    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          home: _InitStateScopeReader(container: container),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('scope available'), findsOneWidget);
  });
}

class _InitStateScopeReader extends StatefulWidget {
  const _InitStateScopeReader({required this.container});

  final AppContainer container;

  @override
  State<_InitStateScopeReader> createState() =>
      _InitStateScopeReaderState();
}

class _InitStateScopeReaderState extends State<_InitStateScopeReader> {
  bool _available = false;

  @override
  void initState() {
    super.initState();
    _available = identical(AppScope.of(context), widget.container);
  }

  @override
  Widget build(BuildContext context) {
    return Text(_available ? 'scope available' : 'scope unavailable');
  }
}
