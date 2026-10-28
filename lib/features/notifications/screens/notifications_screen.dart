import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/notification.dart';

/// Notification history (safety, geofence, incident, emergency, weather).
/// Supports read/unread state and deep-links to the relevant feature.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  AppContainer get _c => AppScope.of(context);

  List<AppNotification> _items = const <AppNotification>[];
  bool _loading = true;
  String? _error;
  bool _unauthenticated = false;
  bool _permissionDenied = false;
  StreamSubscription<List<AppNotification>>? _sub;
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _listen();
    // Re-resolve the screen if the user signs in/out while it is open.
    _authSub = _c.authRepository.authStateChanges().listen((User? u) {
      if (mounted) _listen();
    });
  }

  void _listen() {
    _sub?.cancel();
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      // Unauthenticated: an honest state, not a Firestore call that pretends
      // a permission error is a normal empty list.
      if (mounted) {
        setState(() {
          _items = const <AppNotification>[];
          _loading = false;
          _unauthenticated = true;
          _permissionDenied = false;
          _error = null;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _unauthenticated = false;
      _permissionDenied = false;
      _error = null;
    });
    _sub = _c.notificationsRepository
        .watchMine(uid)
        .listen((List<AppNotification> items) {
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
          _unauthenticated = false;
          _permissionDenied = false;
          _error = null;
        });
      }
    }, onError: (Object e) {
      if (!mounted) return;
      final bool permDenied =
          e is FirebaseException && e.code == 'permission-denied';
      setState(() {
        _permissionDenied = permDenied;
        _error = permDenied
            ? 'Your account cannot read notifications yet — the Firestore '
                'security rules for users/{uid}/notifications need to be '
                'deployed once from this repository.'
            : 'Could not load notifications. Check your connection and retry.';
        _loading = false;
      });
    });
  }

  Future<void> _markAllRead() async {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    final List<String> ids =
        _items.where((AppNotification n) => !n.read).map((AppNotification n) => n.id).toList();
    if (ids.isEmpty) return;
    try {
      await _c.notificationsRepository.markAllRead(uid, ids);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      }
    }
  }

  Future<void> _open(AppNotification n) async {
    if (!n.read) {
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid != null) {
        await _c.notificationsRepository
            .markRead(uid, n.id)
            .catchError((Object _) {});
      }
    }
    final String? incidentId = n.payload['incidentId'] as String?;
    final String? emergencyId = n.payload['emergencyId'] as String?;
    final String destination = switch (n.type) {
      'incident' => incidentId != null ? '/incidents/$incidentId' : '/incidents',
      'emergency' => emergencyId != null ? '/safety' : '/safety',
      'geofence' => '/safety',
      'safety_alert' => '/safety',
      'weather' => '/weather',
      _ => '/home',
    };
    if (!mounted) return;
    unawaited(context.push(destination));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  (IconData, Color) _typeMeta(AppNotification n) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return switch (n.type) {
      'emergency' => (Icons.sos, AppTheme.danger),
      'safety_alert' => (Icons.warning_amber, AppTheme.danger),
      'geofence' => (Icons.gps_not_fixed, AppTheme.warning),
      'incident' => (Icons.report_problem, scheme.primary),
      'weather' => (Icons.wb_cloudy, const Color(0xFF2563EB)),
      _ => (Icons.notifications, scheme.onSurfaceVariant),
    };
  }

  /// Actionable view for a Firestore permission-denied error: tells the user
  /// exactly how to fix it (deploy the rules from this repository) with a
  /// one-tap copy of the command.
  Widget _permissionDeniedView(ColorScheme scheme) {
    const String command =
        'bash scripts/deploy-rules.sh';
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.cloud_off, size: 56, color: scheme.error),
          const SizedBox(height: 16),
          Text(
            'Notifications are blocked by security rules',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Your account is signed in, but the deployed Firestore rules do '
            'not allow reading users/{uid}/notifications yet.\n\n'
            'Fix: from the project folder run the rules deploy (one command, '
            'needs Firebase CLI login once):',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF101418),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              command,
              style: TextStyle(
                color: Color(0xFF9FE8A0),
                fontSize: 12.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: <Widget>[
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy command'),
                onPressed: () async {
                  await Clipboard.setData(
                      const ClipboardData(text: command));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Command copied to clipboard.')),
                    );
                  }
                },
              ),
              FilledButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Try again'),
                onPressed: _listen,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'After the deploy, notifications load automatically — '
            'no reinstall needed.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int unread = _items.where((AppNotification n) => !n.read).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: <Widget>[
          if (unread > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$unread',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          if (unread > 0)
            IconButton(
              icon: const Icon(Icons.done_all),
              tooltip: 'Mark all as read',
              onPressed: _markAllRead,
            ),
        ],
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: SkeletonList(count: 6, height: 84),
            )
          : _unauthenticated
              ? EmptyState(
                  icon: Icons.lock_outline,
                  title: 'Sign in to view your notifications.',
                  message:
                      'Safety alerts, zone entries and incident updates are '
                      'stored per account.',
                  actionLabel: 'Sign in',
                  onAction: () => context.go('/login'),
                )
              : _permissionDenied
                  ? _permissionDeniedView(scheme)
                  : _error != null
                      ? ErrorState(message: _error!, onRetry: _listen)
                      : _items.isEmpty
                          ? const EmptyState(
                              icon: Icons.notifications_none,
                              title: 'No notifications yet.',
                              message:
                                  'Safety alerts, zone entries, incident '
                                  'updates and weather warnings will appear '
                                  'here.',
                            )
                          : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _items.length,
                      itemBuilder: (BuildContext context, int i) {
                        final AppNotification n = _items[i];
                        final (IconData icon, Color color) = _typeMeta(n);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: n.read
                              ? scheme.surface
                              : scheme.surfaceContainerHighest,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                                color: scheme.outlineVariant.withValues(alpha: 0.5)),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _open(n),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: <Widget>[
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: color.withValues(alpha: 0.12),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(icon, size: 20, color: color),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Row(
                                          children: <Widget>[
                                            Expanded(
                                              child: Text(
                                                n.title,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.copyWith(
                                                        fontWeight: n.read
                                                            ? FontWeight.w500
                                                            : FontWeight.w800),
                                              ),
                                            ),
                                            if (!n.read)
                                              Container(
                                                width: 8,
                                                height: 8,
                                                margin: const EdgeInsets.only(
                                                    left: 8),
                                                decoration: BoxDecoration(
                                                  color: scheme.primary,
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          n.body,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          Fmt.relative(n.createdAt),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(Icons.chevron_right,
                                      size: 18,
                                      color: scheme.onSurfaceVariant),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
