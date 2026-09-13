import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'core/services/geofence_service.dart';
import 'core/state/app_container.dart';
import 'core/state/auth_state.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/sos_fab.dart';
import 'core/widgets/sos_sheet.dart';

/// Main navigation shell: bottom bar + global SOS action + profile avatar at
/// the top-right.
///
/// Also owns the geofence lifecycle: monitoring starts when signed in and
/// stops on sign-out. Geofence alerts raise a modal in-app warning with
/// direct access to safety info and SOS.
///
/// System back-button behavior: back from any tab returns to Home first
/// (one step back, never an instant exit), and back on Home requires a
/// double-press within 2 seconds to close the app.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final List<String> _tabs = <String>[
    '/home',
    '/explore',
    '/map',
    '/safety',
    '/vehicle',
  ];
  StreamSubscription<GeofenceAlert>? _geofenceAlerts;
  bool _authed = false;
  bool _startedGeofence = false;
  DateTime? _lastBackPress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppContainer c = AppScope.of(context);
    _geofenceAlerts ??= c.geofenceService.alerts.listen(_onGeofenceAlert);
    _syncGeofence(c);
  }

  void _syncGeofence(AppContainer c) {
    final bool authed = c.authState.status == AuthStatus.authenticated;
    if (authed != _authed) {
      _authed = authed;
      if (authed && !_startedGeofence) {
        _startedGeofence = true;
        unawaited(c.geofenceService.start().catchError((Object _) {}));
      } else if (!authed && _startedGeofence) {
        _startedGeofence = false;
        unawaited(c.geofenceService.stop().catchError((Object _) {}));
      }
    }
  }

  void _onGeofenceAlert(GeofenceAlert alert) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: !alert.zone.isHighRisk,
      builder: (BuildContext ctx) {
        final Color color = alert.zone.isHighRisk
            ? AppTheme.danger
            : AppTheme.warning;
        return AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: color, size: 40),
          title: Text('You entered: ${alert.zone.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'This area is flagged as ${alert.zone.riskLabel.toLowerCase()}.',
              ),
              if (alert.zone.description.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(alert.zone.description,
                    style: Theme.of(ctx).textTheme.bodySmall),
              ],
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                context.push('/safety');
              },
              child: const Text('Safety info'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: color),
              onPressed: () {
                // Use the shell's own context (still mounted) for the sheet.
                final BuildContext rootCtx = context;
                Navigator.of(ctx).pop();
                showSOSSheet(rootCtx);
              },
              child: const Text('SOS'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _geofenceAlerts?.cancel();
    super.dispose();
  }

  int _indexOf(String location) {
    for (int i = 0; i < _tabs.length; i++) {
      if (location.startsWith(_tabs[i])) return i;
    }
    return 0;
  }

  /// Handles the system back button when the shell route itself is on top
  /// (dialogs, sheets and pushed pages above it pop on their own first).
  void _handleSystemBack() {
    final GoRouter router = GoRouter.of(context);
    // Safety net: if anything is still above us, pop it.
    if (router.canPop()) {
      router.pop();
      return;
    }
    final String location = GoRouterState.of(context).matchedLocation;
    // One step back: any tab other than Home goes to Home first.
    if (location != '/home') {
      context.go('/home');
      return;
    }
    // On Home: require a double-press within 2 seconds to exit.
    final DateTime now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final String location = GoRouterState.of(context).matchedLocation;
    final int index = _indexOf(location);
    final bool onTab = _tabs.contains(location);
    final AppContainer c = AppScope.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _handleSystemBack();
      },
      child: Scaffold(
        body: Stack(
          children: <Widget>[
            widget.child,
            // Profile avatar pinned to the top-right on every tab.
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: _profileAvatar(c),
                ),
              ),
            ),
          ],
        ),
        floatingActionButton: const SosFab(),
        bottomNavigationBar: onTab
            ? NavigationBar(
                selectedIndex: index,
                onDestinationSelected: (int i) => context.go(_tabs[i]),
                destinations: const <NavigationDestination>[
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: 'Home',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.explore_outlined),
                    selectedIcon: Icon(Icons.explore),
                    label: 'Explore',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.map_outlined),
                    selectedIcon: Icon(Icons.map),
                    label: 'Map',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.shield_outlined),
                    selectedIcon: Icon(Icons.shield),
                    label: 'Safety',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.directions_car_outlined),
                    selectedIcon: Icon(Icons.directions_car),
                    label: 'Vehicle',
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Widget _profileAvatar(AppContainer c) {
    final User? user = c.authRepository.currentUser;
    final String? photo = user?.photoURL;
    final String initial =
        (user?.displayName?.isNotEmpty ?? false) ? user!.displayName![0].toUpperCase() : '?';
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => context.push('/profile'),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface,
            border: Border.all(color: scheme.outline),
            boxShadow: AppTheme.softShadow(context),
          ),
          child: ClipOval(
            child: (photo != null && photo.isNotEmpty)
                ? Image.network(
                    photo,
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                    errorBuilder: (BuildContext context, Object e,
                            StackTrace? s) =>
                        Center(
                      child: Text(
                        initial,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  )
                : Center(
                    child: Text(
                      initial,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
