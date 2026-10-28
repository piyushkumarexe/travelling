import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/badges.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/incident.dart';

/// Incident detail: media, AI analysis, location, status — and status
/// management for administrators (server-side enforced).
class IncidentDetailScreen extends StatefulWidget {
  const IncidentDetailScreen({super.key, required this.id});

  final String id;

  @override
  State<IncidentDetailScreen> createState() => _IncidentDetailScreenState();
}

class _IncidentDetailScreenState extends State<IncidentDetailScreen> {
  AppContainer get _c => AppScope.of(context);

  Incident? _incident;
  bool _loading = true;
  String? _error;
  bool _photoFailed = false;
  StreamSubscription<Incident?>? _sub;

  static const List<String> _statuses = <String>[
    'reported',
    'under_review',
    'resolved',
    'dismissed',
  ];

  @override
  void initState() {
    super.initState();
    _sub = _c.incidentsRepository
        .watchOne(widget.id)
        .listen((Incident? inc) {
      if (mounted) {
        setState(() {
          _incident = inc;
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

  bool get _isAdmin => _c.authState.isAdmin;

  Future<void> _setStatus(String status) async {
    final Incident? inc = _incident;
    if (inc == null) return;
    try {
      await _c.incidentsRepository.updateStatus(inc.id, status);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Status updated to "$status".')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update status: $e')),
        );
      }
    }
  }

  Future<void> _openVideo(String url) async {
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No app found to play this video on device.')),
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Incident')),
        body: const LoadingView(message: 'Loading incident…'),
      );
    }
    if (_error != null || _incident == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Incident')),
        body: ErrorState(message: _error ?? 'Incident not found.'),
      );
    }
    final Incident inc = _incident!;
    return Scaffold(
      appBar: AppBar(title: Text(inc.categoryLabel)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusBadge(
                label: inc.severityLabel,
                color: RiskBadge.colorFor(context, inc.severity),
              ),
              const SizedBox(width: 8),
              StatusBadge(label: inc.statusLabel),
              const Spacer(),
              Text(
                Fmt.dateTime(inc.createdAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 16),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Description',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(inc.description,
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          if ((inc.photoUrl ?? inc.videoUrl) != null) ...<Widget>[
            const SizedBox(height: 12),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Attached media',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  if (inc.photoUrl != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: _photoFailed
                          ? Container(
                              height: 160,
                              color: scheme.surfaceContainerHighest,
                              child: const Center(
                                  child: Icon(Icons.broken_image)),
                            )
                          : Image.network(
                              inc.photoUrl!,
                              height: 200,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (BuildContext context,
                                  Object error, StackTrace? stackTrace) {
                                if (!mounted) return const SizedBox.shrink();
                                setState(() => _photoFailed = true);
                                return Container(
                                  height: 200,
                                  color: scheme.surfaceContainerHighest,
                                  child: const Center(
                                      child: Icon(Icons.broken_image)),
                                );
                              },
                            ),
                    ),
                  if (inc.videoUrl != null) ...<Widget>[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.play_circle_outline),
                      label: const Text('Play video'),
                      onPressed: () => _openVideo(inc.videoUrl!),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if ((inc.summary ?? '').isNotEmpty ||
              (inc.recommendedAction ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.auto_awesome,
                          size: 18, color: AppTheme.warning),
                      const SizedBox(width: 8),
                      Text(
                        'AI analysis',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  if ((inc.summary ?? '').isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(inc.summary!,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                  if ((inc.recommendedAction ?? '').isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      'Recommended action',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    Text(inc.recommendedAction!,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          AppCard(
            child: Row(
              children: <Widget>[
                Icon(Icons.place, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Location',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${inc.lat.toStringAsFixed(5)}, ${inc.lng.toStringAsFixed(5)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.map, size: 18),
                  label: const Text('Map'),
                  onPressed: () => context.push(
                      '/map?lat=${inc.lat}&lng=${inc.lng}&name=incident'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Reported by: ${inc.reporterName}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_isAdmin) ...<Widget>[
            const SizedBox(height: 16),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Admin — update status',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: inc.status,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: <DropdownMenuItem<String>>[
                      for (final String s in _statuses)
                        DropdownMenuItem<String>(
                          value: s,
                          child: Text(_label(s)),
                        ),
                    ],
                    onChanged: (String? v) {
                      if (v != null && v != inc.status) _setStatus(v);
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _label(String s) =>
      s == 'under_review' ? 'Under review' : s[0].toUpperCase() + s.substring(1);
}
