import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/eco_tracker.dart';
import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/eco_math.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../data/models/eco.dart';

/// Eco Score: track walking / cycling / public transport. Sessions can be
/// GPS-tracked live or logged manually; the score persists in Firestore.
class EcoScreen extends StatefulWidget {
  const EcoScreen({super.key});

  @override
  State<EcoScreen> createState() => _EcoScreenState();
}

class _EcoScreenState extends State<EcoScreen> {
  AppContainer get _c => AppScope.of(context);

  EcoScore? _score;
  List<EcoActivity> _activities = const <EcoActivity>[];
  bool _loading = true;
  String? _error;

  StreamSubscription<EcoScore?>? _scoreSub;
  StreamSubscription<List<EcoActivity>>? _actSub;
  late VoidCallback _trackerListener;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _trackerListener = () {
      if (mounted) setState(() {});
    };
    _c.ecoTracker.addListener(_trackerListener);
    _listen();
  }

  void _listen() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    _scoreSub = _c.ecoRepository
        .watchScore(uid)
        .listen((EcoScore? s) {
      if (mounted) {
        setState(() {
          _score = s;
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
    _actSub = _c.ecoRepository
        .watchActivities(uid)
        .listen((List<EcoActivity> items) {
      if (mounted) setState(() => _activities = items);
    }, onError: (Object _) {});
  }

  Future<void> _startSession() async {
    final String? mode = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('Start eco session'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('walk'),
            child: const Row(
              children: <Widget>[
                Icon(Icons.directions_walk),
                SizedBox(width: 12),
                Text('Walking (GPS-tracked)'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('cycle'),
            child: const Row(
              children: <Widget>[
                Icon(Icons.directions_bike),
                SizedBox(width: 12),
                Text('Cycling (GPS-tracked)'),
              ],
            ),
          ),
        ],
      ),
    );
    if (mode == null) return;
    try {
      await _c.ecoTracker.start(mode: mode);
      if (!mounted) return;
      if (!_c.ecoTracker.isTracking) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Location permission denied — enable location access in system settings to track eco sessions.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not start: $e')));
      }
    }
  }

  Future<void> _stopAndLog() async {
    final EcoSession? session = await _c.ecoTracker.stop();
    if (session == null) return;
    if (session.distanceMeters < 50) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Session too short (under 50 m) — nothing was logged.')),
        );
      }
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Log this session?'),
        content: Text(
          '${EcoMath.modeLabel(session.mode)} · '
          '${GeoUtils.formatDistance(session.distanceMeters)} · '
          '${GeoUtils.formatDuration(session.duration.inSeconds)}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Log activity'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _saveActivity(
      mode: session.mode,
      distanceMeters: session.distanceMeters,
      durationSeconds: session.duration.inSeconds.toDouble(),
      note: 'GPS session',
    );
  }

  Future<void> _saveActivity({
    required String mode,
    required double distanceMeters,
    required double durationSeconds,
    String? note,
  }) async {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    setState(() => _saving = true);
    try {
      await _c.ecoRepository.addActivity(
        uid,
        EcoActivity(
          id: '',
          uid: uid,
          mode: mode,
          distanceMeters: distanceMeters,
          durationSeconds: durationSeconds,
          note: note,
          createdAt: DateTime.now(),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Eco activity logged — score updated.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not log: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _logManual() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) =>
          _ManualLogSheet(onSave: _saveActivity, saving: _saving),
    );
  }

  @override
  void dispose() {
    _scoreSub?.cancel();
    _actSub?.cancel();
    _c.ecoTracker.removeListener(_trackerListener);
    super.dispose();
  }

  String _nextLevelHint(int score) {
    final int idx = EcoMath.levelIndexFor(score);
    if (idx >= EcoMath.scoreLevels.length - 1) {
      return 'Highest level reached — keep it up!';
    }
    final int next = EcoMath.scoreLevels[idx + 1];
    return 'Next level (${EcoMath.scoreLevelNames[idx + 1]}) in '
        '${(next - score).round()} pts';
  }

  Widget _statCard(IconData icon, String label, String value) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          Icon(icon, color: scheme.primary),
          const SizedBox(height: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
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
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Eco Score')),
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            children: <Widget>[
              SkeletonCard(height: 180),
              SizedBox(height: 12),
              SkeletonList(count: 3, height: 80),
            ],
          ),
        ),
      );
    }
    final EcoScore score = _score ?? EcoScore(uid: '');
    final EcoSession? session = _c.ecoTracker.session;
    return Scaffold(
      appBar: AppBar(title: const Text('Eco Score')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving ? null : _logManual,
        icon: const Icon(Icons.add),
        label: const Text('Log activity'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: <Widget>[
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.error_outline, color: scheme.onErrorContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(color: scheme.onErrorContainer)),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Color(0xFF1B5E20), Color(0xFF43A047)],
              ),
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.eco, color: Colors.white, size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        EcoMath.levelFor(score.score),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text(
                      '${score.score} pts',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: EcoMath.levelProgress(score.score),
                    minHeight: 10,
                    backgroundColor: Colors.white24,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _nextLevelHint(score.score),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _statCard(Icons.directions_walk, 'Walking',
                    GeoUtils.formatDistance(score.walkKm * 1000)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statCard(Icons.pedestal, 'Cycling',
                    GeoUtils.formatDistance(score.cycleKm * 1000)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statCard(Icons.train, 'Transit',
                    GeoUtils.formatDistance(score.transitKm * 1000)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (session != null)
            AppCard(
              color: AppTheme.success.withValues(alpha: 0.08),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.gps_fixed, color: AppTheme.success),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Tracking ${EcoMath.modeLabel(session.mode)}…',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Distance: ${GeoUtils.formatDistance(session.distanceMeters)}'
                    ' · Time: ${GeoUtils.formatDuration(session.duration.inSeconds)}'
                    '${session.hasFixes ? '' : ' · waiting for GPS fixes…'}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: 'Stop & log session',
                    icon: Icons.stop,
                    danger: true,
                    onPressed: _stopAndLog,
                  ),
                ],
              ),
            )
          else
            AppCard(
              onTap: _startSession,
              child: Row(
                children: <Widget>[
                  Icon(Icons.directions_walk, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Start a GPS-tracked session',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Keep the app open while you walk or cycle; YatraWise '
                          'measures real distance from GPS.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Text(
            'Badges',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              for (final MapEntry<String, (String, String, int)> entry
                  in EcoMath.badges.entries)
                _badgeChip(
                  id: entry.key,
                  name: entry.value.$1,
                  description: entry.value.$2,
                  unlocked: score.badges.contains(entry.key),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Recent activity',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (_activities.isEmpty)
            AppCard(
              child: Text(
                'No activities yet. Start a GPS session or log one manually.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            )
          else
            Column(
              children: <Widget>[
                for (final EcoActivity a in _activities.take(10))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Row(
                        children: <Widget>[
                          Icon(_modeIcon(a.mode), color: scheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  '${EcoMath.modeLabel(a.mode)} · '
                                  '${GeoUtils.formatDistance(a.distanceMeters)}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                          fontWeight: FontWeight.w700),
                                ),
                                Text(
                                  '${GeoUtils.formatDuration(a.durationSeconds.toInt())}'
                                  ' · ${Fmt.dateTime(a.createdAt)}'
                                  '${a.note != null && a.note!.isNotEmpty ? ' · ${a.note}' : ''}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '+${EcoMath.activityPoints(a.mode, a.distanceMeters)} pts',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.success,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  IconData _modeIcon(String mode) => switch (mode) {
        'walk' => Icons.directions_walk,
        'cycle' => Icons.pedestal,
        _ => Icons.train,
      };

  Widget _badgeChip({
    required String id,
    required String name,
    required String description,
    required bool unlocked,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: description,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: unlocked
              ? AppTheme.success.withValues(alpha: 0.12)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: unlocked
                ? AppTheme.success.withValues(alpha: 0.5)
                : scheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              unlocked ? Icons.emoji_events : Icons.lock,
              size: 16,
              color: unlocked ? AppTheme.success : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              name,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: unlocked
                        ? AppTheme.success
                        : scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManualLogSheet extends StatefulWidget {
  const _ManualLogSheet({required this.onSave, required this.saving});

  final Future<void> Function({
    required String mode,
    required double distanceMeters,
    required double durationSeconds,
    String? note,
  }) onSave;
  final bool saving;

  @override
  State<_ManualLogSheet> createState() => _ManualLogSheetState();
}

class _ManualLogSheetState extends State<_ManualLogSheet> {
  String _mode = 'walk';
  final TextEditingController _distanceController = TextEditingController();
  final TextEditingController _durationController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _distanceController.dispose();
    _durationController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String distText = _distanceController.text.trim();
    final String durText = _durationController.text.trim();
    final double? km = double.tryParse(distText);
    if (km == null || km <= 0 || km > 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enter a distance between 0 and 500 km.')),
      );
      return;
    }
    final double durMin = durText.isEmpty ? 30 : (double.tryParse(durText) ?? 30);
    await widget.onSave(
      mode: _mode,
      distanceMeters: km * 1000,
      durationSeconds: durMin * 60,
      note: _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim(),
    );
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Log eco activity',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(
                  value: 'walk', label: Text('Walk'),
                  icon: Icon(Icons.directions_walk, size: 16)),
              ButtonSegment<String>(
                  value: 'cycle', label: Text('Cycle'),
                  icon: Icon(Icons.pedestal, size: 16)),
              ButtonSegment<String>(
                  value: 'transit', label: Text('Transit'),
                  icon: Icon(Icons.train, size: 16)),
            ],
            selected: <String>{_mode},
            onSelectionChanged: (Set<String> s) {
              setState(() => _mode = s.first);
            },
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _distanceController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration:
                      const InputDecoration(labelText: 'Distance (km)'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _durationController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration:
                      const InputDecoration(labelText: 'Minutes (optional)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(
                labelText: 'Note (optional)', maxLength: 120),
          ),
          const SizedBox(height: 18),
          PrimaryButton(
            label: 'Log activity',
            icon: Icons.check,
            loading: widget.saving,
            onPressed: widget.saving ? null : _save,
          ),
        ],
      ),
    );
  }
}
