import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/badges.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/incident.dart';

/// The user's submitted incident reports with live statuses.
class IncidentHistoryScreen extends StatefulWidget {
  const IncidentHistoryScreen({super.key});

  @override
  State<IncidentHistoryScreen> createState() => _IncidentHistoryScreenState();
}

class _IncidentHistoryScreenState extends State<IncidentHistoryScreen> {
  AppContainer get _c => AppScope.of(context);

  List<Incident> _items = const <Incident>[];
  bool _loading = true;
  String? _error;
  StreamSubscription<List<Incident>>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    _sub = _c.incidentsRepository
        .watchMine(uid)
        .listen((List<Incident> items) {
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

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Incident history')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/incidents/report'),
        icon: const Icon(Icons.add),
        label: const Text('Report incident'),
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: SkeletonList(count: 4, height: 120),
            )
          : _error != null
              ? ErrorState(message: _error!, onRetry: _listen)
              : _items.isEmpty
                  ? EmptyState(
                      icon: Icons.report_problem,
                      title: 'No incidents reported',
                      message:
                          'When you submit a report, it appears here with its status and AI analysis.',
                      actionLabel: 'Report an incident',
                      onAction: () => context.push('/incidents/report'),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      itemCount: _items.length,
                      itemBuilder: (BuildContext context, int i) {
                        final Incident inc = _items[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: AppCard(
                            onTap: () => context.push('/incidents/${inc.id}'),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Icon(
                                      _iconFor(inc),
                                      color: RiskBadge.colorFor(
                                          context, inc.severity),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        inc.categoryLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                                fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                    StatusBadge(
                                      label: inc.severityLabel,
                                      color: RiskBadge.colorFor(
                                          context, inc.severity),
                                    ),
                                    const SizedBox(width: 8),
                                    StatusBadge(label: inc.statusLabel),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  inc.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: <Widget>[
                                    Text(
                                      Fmt.dateTime(inc.createdAt),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                    const Spacer(),
                                    if (inc.photoUrl != null)
                                      const Padding(
                                        padding: EdgeInsets.only(right: 8),
                                        child: Icon(Icons.photo, size: 14),
                                      ),
                                    if (inc.videoUrl != null)
                                      const Icon(Icons.videocam, size: 14),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }

  IconData _iconFor(Incident inc) {
    return switch (inc.category) {
      'theft' => Icons.privacy_tip,
      'fraud' => Icons.swap_horiz,
      'assault' => Icons.report_gmailerrorred,
      'harassment' => Icons.speaker_notes_off,
      'accident' => Icons.car_crash,
      'unsafe_area' => Icons.warning_amber,
      'poor_infrastructure' => Icons.construction,
      'natural_hazard' => Icons.storm,
      _ => Icons.report_problem,
    };
  }
}
