import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/badges.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/emergency_event.dart';
import '../../../data/models/incident.dart';
import '../../../data/models/safety_zone.dart';

/// Administrator console (server-side enforced via security rules):
/// all incidents, all emergencies, and the safety-zone catalog.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  AppContainer get _c => AppScope.of(context);

  List<Incident> _incidents = const <Incident>[];
  List<EmergencyEvent> _emergencies = const <EmergencyEvent>[];
  List<SafetyZone> _zones = const <SafetyZone>[];
  bool _loading = true;
  String? _error;

  StreamSubscription<List<Incident>>? _incSub;
  StreamSubscription<List<EmergencyEvent>>? _emgSub;
  StreamSubscription<List<SafetyZone>>? _zoneSub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _incSub = _c.incidentsRepository
        .watchAll()
        .listen((List<Incident> items) {
      if (mounted) {
        setState(() {
          _incidents = items;
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
    _emgSub = _c.emergencyRepository
        .watchAll()
        .listen((List<EmergencyEvent> items) {
      if (mounted) {
        setState(() {
          _emergencies = items;
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
    _zoneSub = _c.zonesRepository
        .watchAll()
        .listen((List<SafetyZone> items) {
      if (mounted) {
        setState(() {
          _zones = items;
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

  Future<void> _resolveEmergency(EmergencyEvent e) async {
    try {
      await _c.emergencyRepository.updateStatus(e.id, 'resolved');
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update failed: $err')));
      }
    }
  }

  Future<void> _toggleZone(SafetyZone z, bool active) async {
    try {
      await _c.zonesRepository.update(z.id, <String, dynamic>{'active': active});
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update failed: $err')));
      }
    }
  }

  @override
  void dispose() {
    _incSub?.cancel();
    _emgSub?.cancel();
    _zoneSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Admin console'),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(text: 'Incidents'),
              Tab(text: 'Emergencies'),
              Tab(text: 'Zones'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => context.go('/admin/zone/new'),
          icon: const Icon(Icons.add),
          label: const Text('New zone'),
        ),
        body: _loading
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: SkeletonList(count: 5, height: 90),
              )
            : _error != null
                ? ErrorState(message: _error!, onRetry: _listen)
                : TabBarView(
                    children: <Widget>[
                      _incidentsTab(scheme),
                      _emergenciesTab(scheme),
                      _zonesTab(scheme),
                    ],
                  ),
      ),
    );
  }

  Widget _incidentsTab(ColorScheme scheme) {
    if (_incidents.isEmpty) {
      return const EmptyState(
        icon: Icons.report_problem,
        title: 'No incidents reported yet',
        message: 'User incident reports will appear here for review.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _incidents.length,
      itemBuilder: (BuildContext context, int i) {
        final Incident inc = _incidents[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            onTap: () => context.go('/incidents/${inc.id}'),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        inc.categoryLabel,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${inc.reporterName} · ${Fmt.relative(inc.createdAt)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                StatusBadge(
                  label: inc.severityLabel,
                  color: RiskBadge.colorFor(context, inc.severity),
                ),
                const SizedBox(width: 6),
                StatusBadge(label: inc.statusLabel),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _emergenciesTab(ColorScheme scheme) {
    if (_emergencies.isEmpty) {
      return const EmptyState(
        icon: Icons.sos,
        title: 'No emergency events',
        message: 'SOS activations by users will appear here.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _emergencies.length,
      itemBuilder: (BuildContext context, int i) {
        final EmergencyEvent e = _emergencies[i];
        final bool active = e.status == 'active';
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(
                  active ? Icons.sos : Icons.check_circle,
                  color: active ? AppTheme.danger : AppTheme.success,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${e.name} · SOS',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${e.lat.toStringAsFixed(5)}, ${e.lng.toStringAsFixed(5)}'
                        ' · ${Fmt.relative(e.createdAt)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                StatusBadge(
                  label: e.statusLabel,
                  color: active
                      ? AppTheme.danger
                      : (e.status == 'resolved' ? AppTheme.success : AppTheme.warning),
                ),
                if (active)
                  TextButton(
                    onPressed: () => _resolveEmergency(e),
                    child: const Text('Resolve'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _zonesTab(ColorScheme scheme) {
    if (_zones.isEmpty) {
      return const EmptyState(
        icon: Icons.location_off,
        title: 'No safety zones configured',
        message: 'Create zones to warn travelers about risky areas.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _zones.length,
      itemBuilder: (BuildContext context, int i) {
        final SafetyZone z = _zones[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        z.name,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${z.lat.toStringAsFixed(5)}, ${z.lng.toStringAsFixed(5)}'
                        ' · ${GeoRadius.format(z.radiusMeters)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                RiskBadge(risk: z.riskLevel),
                const SizedBox(width: 8),
                Switch(
                  value: z.active,
                  onChanged: (bool v) => _toggleZone(z, v),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: 'Edit zone',
                  onPressed: () => context.go('/admin/zone/${z.id}'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class GeoRadius {
  GeoRadius._();
  static String format(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
}
