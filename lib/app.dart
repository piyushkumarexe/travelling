import 'package:flutter/material.dart';

import 'core/router/app_router.dart';
import 'core/state/app_container.dart';
import 'core/state/theme_controller.dart';
import 'core/theme/app_theme.dart';
import 'features/setup/screens/setup_guide_screen.dart';

class TourismApp extends StatelessWidget {
  const TourismApp({super.key, required this.container});

  final AppContainer container;

  @override
  Widget build(BuildContext context) {
    // When Firebase is not configured yet, show a guided setup screen
    // instead of a broken app (honest, actionable state).
    if (!container.firebaseReady) {
      return ValueListenableBuilder<ThemeMode>(
        valueListenable: themeModeNotifier,
        builder: (BuildContext context, ThemeMode mode, Widget? child) =>
            MaterialApp(
          title: 'Tourism',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          home: const SetupGuideScreen(),
        ),
      );
    }

    final AppRouter appRouter = AppRouter(container: container);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (BuildContext context, ThemeMode mode, Widget? child) =>
          AppScope(
        container: container,
        child: MaterialApp.router(
          title: 'Tourism',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          routerConfig: appRouter.router,
        ),
      ),
    );
  }
}
