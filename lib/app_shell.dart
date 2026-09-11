import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/services/geofence_service.dart';
import 'core/state/app_container.dart';
import 'core/state/auth_state.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/creator_mark.dart';
import 'core/widgets/sos_fab.dart';
import 'core/widgets/sos_sheet.dart';

/// Main navigation shell: bottom bar + global SOS action.
///
/// Also owns the geofence lifecycle: monitoring starts when signed in and
/// stops on sign-out. Geofence alerts raise a modal in-app warning with
/// direct access to safety info and SOS.
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
    '/profile',
  ];
  StreamSubscription<GeofenceAlert>? _geofenceAlerts;
  bool _authed = false;
  bool _startedGeofence = false;

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
                context.go('/safety');
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

  @override
  Widget build(BuildContext context) {
    final String location = GoRouterState.of(context).matchedLocation;
    final int index = _indexOf(location);
    final bool onTab = _tabs.contains(location);

    return Scaffold(
      body: widget.child,
      floatingActionButton: const SosFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: onTab
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const CreatorMark(
                  padding: EdgeInsets.only(top: 5, bottom: 1),
                ),
                NavigationBar(
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
                    NavigationDestination(
                      icon: Icon(Icons.person_outline),
                      selectedIcon: Icon(Icons.person),
                      label: 'Profile',
                    ),
                  ],
                ),
              ],
            )
          : null,
    );
  }
}
