import 'dart:async';

import 'package:flutter/material.dart';
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
  StreamSubscription<List<AppNotification>>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    _sub = _c.notificationsRepository
        .watchMine(uid)
        .listen((List<AppNotification> items) {
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    }, onError: (Object e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
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
          : _error != null
              ? ErrorState(message: _error!, onRetry: _listen)
              : _items.isEmpty
                  ? const EmptyState(
                      icon: Icons.notifications_none,
                      title: 'No notifications',
                      message:
                          'Safety alerts, zone entries, incident updates and '
                          'weather warnings will appear here.',
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
