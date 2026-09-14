// 🧠 Travel Intelligence — dashboard connected to the EXISTING Trip Planner
// (TripPlanStore) and real services (OSRM via PlacesRepository, live GPS via
// LocationService). What-if runs on a copy until you press Apply. Every
// number comes from the saved plan, parsed costs, or OSRM — nothing invented.

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/network/osrm_client.dart' show RouteInfo;

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/itinerary.dart';
import '../../../data/models/places.dart' show Place;
import '../../../data/models/trip_plan.dart';
import '../engine/decision_replay_store.dart';
import '../engine/engine_models.dart';
import '../engine/trip_intelligence_engine.dart';

class TravelIntelligenceScreen extends StatefulWidget {
  const TravelIntelligenceScreen({super.key});

  @override
  State<TravelIntelligenceScreen> createState() =>
      _TravelIntelligenceScreenState();
}

class _TravelIntelligenceScreenState extends State<TravelIntelligenceScreen> {
  AppContainer get _c => AppScope.of(context);

  final DecisionReplayStore _replay = DecisionReplayStore();

  @override
  void initState() {
    super.initState();
    _replay.load();
  }

  /// The active trip from the EXISTING planner — never a copy stored here.
  TripPlan? get _trip => _c.tripPlanStore.active;

  List<ItineraryDay> get _plan => <ItineraryDay>[
        for (final day in (_trip?.plan ?? const <ItineraryDay>[])) day,
      ];

  @override
  Widget build(BuildContext context) {
    final TripPlan? trip = _trip;
    return Scaffold(
      appBar: AppBar(title: const Text('🧠 Travel Intelligence')),
      body: trip == null || trip.plan.isEmpty
          ? EmptyState(
              icon: Icons.psychology,
              title: 'No active trip plan',
              message:
                  'Travel Intelligence works on your saved Trip Planner plan '
                  '(its stops, times and costs). Create a trip in the planner '
                  'first, then come back — every calculation here runs on '
                  'that real data.',
              actionLabel: 'Open Trip Planner',
              onAction: () => context.push('/planner'),
            )
          : _build(trip),
      bottomNavigationBar: const Padding(
        padding: EdgeInsets.all(10),
        child: Text('TRAVEL-INTELLIGENCE-BUILD-2026-09-14-01',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: Colors.grey)),
      ),
    );
  }

  Widget _build(TripPlan trip) {
    final List<ItineraryDay> plan = _plan;
    final RobustnessReport robust =
        TripIntelligenceEngine.robustness(plan, budgetBand: trip.budget);
    final List<Contradiction> problems =
        TripIntelligenceEngine.contradictions(plan);
    final (String deadlineText, bool urgent) = _nextDeadline(plan);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        Text('${trip.destination} — ${trip.days} day(s)',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        _robustnessCard(robust),
        const SizedBox(height: 12),
        _problemsCard(problems),
        const SizedBox(height: 12),
        _deadlineCard(deadlineText, urgent),
        const SizedBox(height: 12),
        _toolsGrid(trip),
        const SizedBox(height: 12),
        _behaviourCard(),
      ],
    );
  }

  // ---------------- robustness ----------------

  Widget _robustnessCard(RobustnessReport r) {
    final Color color = r.score >= 80
        ? AppTheme.success
        : r.score >= 60
            ? AppTheme.warning
            : AppTheme.danger;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(children: <Widget>[
            Text('${r.score}',
                style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    color: color)),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('/100 ${r.band}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text('Trip robustness — from buffers, connections, load '
                      'and plan cost',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 8),
          for (final RobustnessFactor f in r.factors.take(4))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    f.impact < 0 ? Icons.warning_amber : Icons.check_circle,
                    size: 15,
                    color: f.impact < 0 ? AppTheme.warning : AppTheme.success,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('${f.name}: ${f.detail}',
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          if (r.score < 80) ...<Widget>[
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => _improveRobustness(),
              icon: const Icon(Icons.healing, size: 16),
              label: const Text('Improve Robustness',
                  style: TextStyle(fontSize: 13)),
            ),
          ],
        ],
      ),
    );
  }

  /// "Improve Robustness" = a concrete relaxation scenario previewed in the
  /// simulator (drop the most overloaded day's tail stop) — never silent.
  Future<void> _improveRobustness() async {
    final TripPlan trip = _trip!;
    final List<ItineraryDay> plan = _plan;
    int worstDay = 0;
    int worstCount = 0;
    for (int i = 0; i < plan.length; i++) {
      if (plan[i].items.length > worstCount) {
        worstCount = plan[i].items.length;
        worstDay = i;
      }
    }
    final SimulationResult sim = TripIntelligenceEngine.simulate(
      plan,
      ScenarioSpec(
          type: ScenarioType.reducedTime,
          availableMinutesPerDay: 600,
          dayIndex: worstDay),
    );
    await _openDiff(
      title: 'Improve Robustness — preview',
      result: sim,
      onApply: () => _applyPlan(
          sim.days, 'Robustness improved', DecisionType.recoveryApplied),
      trip: trip,
    );
  }

  // ---------------- problems + deadline ----------------

  Widget _problemsCard(List<Contradiction> problems) {
    if (problems.isEmpty) {
      return AppCard(
        child: Row(children: <Widget>[
          const Icon(Icons.check_circle, color: AppTheme.success, size: 20),
          const SizedBox(width: 8),
          Expanded(
              child: Text('No schedule contradictions found in the saved plan.',
                  style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Active trip problems (${problems.length})',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          for (final Contradiction c in problems.take(5))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    c.severity == Severity.critical
                        ? Icons.error
                        : c.severity == Severity.warning
                            ? Icons.warning_amber
                            : Icons.info,
                    size: 15,
                    color: c.severity == Severity.critical
                        ? AppTheme.danger
                        : c.severity == Severity.warning
                            ? AppTheme.warning
                            : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text('${c.title} — ${c.detail}',
                          style: const TextStyle(fontSize: 12))),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Earliest "leave by" deadline across consecutive stops in the saved plan
  /// (30-min safety buffer) — real saved times only.
  (String, bool) _nextDeadline(List<ItineraryDay> plan) {
    final int nowMin = DateTime.now().hour * 60 + DateTime.now().minute;
    for (final ItineraryDay d in plan) {
      for (int i = 1; i < d.items.length; i++) {
        final int? t = TripIntelligenceEngine.timeToMin(d.items[i].time);
        if (t == null) continue;
        final (int deadline, String text) =
            TripIntelligenceEngine.lastSafeDeparture(
          legMinutes: 0, // intra-city hop: no real leg data — deadline is
          bufferMinutes: 30, // purely the saved start time minus buffer
          arrivalDeadlineMin: t,
          plannedDepartureMin: t,
        );
        if (nowMin < t) {
          final bool urgent = nowMin >= deadline;
          return (
            'Next: "${d.items[i].title}" at ${d.items[i].time} — be ready to '
                'leave 30 min before. $text',
            urgent
          );
        }
      }
    }
    return ('No upcoming same-day deadline found in the saved plan.', false);
  }

  Widget _deadlineCard(String text, bool urgent) => AppCard(
        child: Row(children: <Widget>[
          Icon(Icons.timer,
              size: 20, color: urgent ? AppTheme.danger : AppTheme.warning),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 12.5))),
        ]),
      );

  // ---------------- tools ----------------

  Widget _toolsGrid(TripPlan trip) {
    final List<(IconData, String, String, VoidCallback)> tools =
        <(IconData, String, String, VoidCallback)>[
      (
        Icons.timelapse,
        'What-If Simulator',
        'Delays, closures, less time/budget — on a copy',
        () => _openSimulator(trip)
      ),
      (
        Icons.tune,
        'Constraints & Trade-offs',
        'Must-visit, limits and sliders that really re-plan',
        () => _openConstraints(trip)
      ),
      (
        Icons.account_tree,
        'Dependency Graph',
        'What depends on what; change impact',
        () => _openGraph(trip)
      ),
      (
        Icons.history,
        'Decision Replay',
        'Your real in-app decisions (${_replay.records.length})',
        () => _openReplay()
      ),
      (
        Icons.healing,
        'Recover Trip',
        'Running late? Re-flow the rest of today',
        () => _openRecovery(trip)
      ),
      (
        Icons.help_center,
        'Why not this place?',
        'Honest reasons against a place you consider',
        () => _openWhyNot(trip)
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Tools', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (final (IconData, String, String, VoidCallback) t in tools)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              onTap: t.$4,
              leading: Icon(t.$1),
              title: Text(t.$2,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
              subtitle: Text(t.$3,
                  style: const TextStyle(fontSize: 11.5)),
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
      ],
    );
  }

  // ---------------- behaviour model ----------------

  Widget _behaviourCard() {
    final List<String> lines = _c.settings.behaviourSummary();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(children: <Widget>[
            const Expanded(
              child: Text('Personal behaviour model',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            TextButton(
              onPressed: () async {
                await _c.settings.resetBehaviour();
                if (mounted) setState(() {});
              }),
              child: const Text('Reset', style: TextStyle(fontSize: 12)),
            ),
          ]),
          Text(
            'Learned only from your in-app planning actions — never location '
            'history, never sensitive traits.',
            style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          for (final String l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('• $l', style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  // ---------------- simulator / apply flows ----------------

  Future<void> _openSimulator(TripPlan trip) async {
    final ScenarioType? type = await showModalBottomSheet<ScenarioType>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final ScenarioType t in ScenarioType.values)
              ListTile(
                title: Text(t.label),
                onTap: () => Navigator.pop(ctx, t),
              ),
          ],
        ),
      ),
    );
    if (type == null || !mounted) return;
    final TextEditingController amountCtrl = TextEditingController(text: '60');
    final SimulationResult? result = await showDialog<SimulationResult>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(type.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: switch (type) {
                    ScenarioType.reducedBudget => 'New budget % of original',
                    ScenarioType.removedStop => 'Stop number to remove (1..n)',
                    _ => 'Delay / change in minutes',
                  }),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final int v = int.tryParse(amountCtrl.text.trim()) ?? 60;
              Navigator.pop(
                  ctx,
                  TripIntelligenceEngine.simulate(
                    _plan,
                    ScenarioSpec(
                      type: type,
                      delayMinutes: v,
                      dayIndex: 0,
                      removeDayIndex: 0,
                      removeItemIndex: (v - 1).clamp(0, _plan.isEmpty ? 0 : _plan.first.items.length - 1),
                      availableMinutesPerDay: v * 60,
                      budgetPct: v.clamp(10, 150),
                    ),
                  ));
            },
            child: const Text('Simulate'),
          ),
        ],
      ),
    );
    amountCtrl.dispose();
    if (result == null || !mounted) return;
    await _openDiff(
      title: '${type.label} — preview',
      result: result,
      onApply: () => _applyPlan(
          result.days, '${type.label} applied', DecisionType.scenarioApplied),
      trip: trip,
    );
  }

  Future<void> _openRecovery(TripPlan trip) async {
    final TextEditingController ctrl = TextEditingController(text: '45');
    final SimulationResult? r = await showDialog<SimulationResult>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Recover: running late'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
                'How many minutes behind schedule are you on day 1? The rest '
                'of the day re-flows on a copy; stops pushed past 23:30 are '
                'reported, not hidden.'),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Minutes late'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(
                  ctx,
                  TripIntelligenceEngine.simulate(
                      _plan,
                      ScenarioSpec(
                          type: ScenarioType.custom,
                          delayMinutes:
                              int.tryParse(ctrl.text.trim()) ?? 45))),
        ],
      ),
    );
    ctrl.dispose();
    if (r == null || !mounted) return;
    await _openDiff(
      title: 'Recovery — preview',
      result: r,
      onApply: () => _applyPlan(
          r.days, 'Recovery plan applied', DecisionType.recoveryApplied),
      trip: trip,
    );
  }

  Future<void> _openConstraints(TripPlan trip) async {
    final TextEditingController must = TextEditingController();
    final TextEditingController avoid = TextEditingController();
    int maxMin = 600;
    int? budgetCap;
    int relaxed = 50, budget = 50, travel = 50, timeExp = 50;
    final SolverResult? r = await showModalBottomSheet<SolverResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setM) =>
            Padding(
          padding: EdgeInsets.fromLTRB(
              16, 8, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              TextField(
                  controller: must,
                  decoration: const InputDecoration(
                      labelText: 'Must visit (comma-separated titles)')),
              TextField(
                  controller: avoid,
                  decoration: const InputDecoration(
                      labelText: 'Avoid (comma-separated keywords)')),
              const SizedBox(height: 8),
              Text('Max time per day: ${(maxMin / 60).toStringAsFixed(1)} h',
                  style: const TextStyle(fontSize: 12.5)),
              Slider(
                  value: maxMin.toDouble(),
                  min: 180,
                  max: 840,
                  divisions: 22,
                  label: '${(maxMin / 60).toStringAsFixed(0)} h',
                  onChanged: (double v) => setM(() => maxMin = v.round())),
              Text('Budget cap (₹, only parsed costs counted)',
                  style: const TextStyle(fontSize: 12.5)),
              Slider(
                  value: (budgetCap ?? 10000).toDouble(),
                  min: 500,
                  max: 20000,
                  divisions: 39,
                  label: '₹${budgetCap ?? 10000}',
                  onChanged: (double v) => setM(() => budgetCap = v.round())),
              const SizedBox(height: 8),
              _slider('Time efficiency ↔ Experience', timeExp,
                  (int v) => setM(() => timeExp = v)),
              _slider('Low budget ↔ Higher budget', budget,
                  (int v) => setM(() => budget = v)),
              _slider('Less travel ↔ More destinations', travel,
                  (int v) => setM(() => travel = v)),
              _slider('Relaxed ↔ Packed', relaxed,
                  (int v) => setM(() => relaxed = v)),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(
                      ctx,
                      TripIntelligenceEngine.optimize(
                        _plan,
                        TradeOffProfile(
                            timeVsExperience: timeExp,
                            budgetPref: budget,
                            travelVsDestinations: travel,
                            relaxedVsPacked: relaxed),
                        ConstraintSet(
                          mustVisit: must.text
                              .split(',')
                              .map((String e) => e.trim())
                              .where((String e) => e.isNotEmpty)
                              .toList(),
                          avoid: avoid.text
                              .split(',')
                              .map((String e) => e.trim())
                              .where((String e) => e.isNotEmpty)
                              .toList(),
                          maxMinutesPerDay: maxMin,
                          budgetCapInr: budgetCap,
                        ),
                      ));
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('Solve on a copy'),
              ),
            ],
          ),
        ),
      ),
    );
    must.dispose();
    avoid.dispose();
    if (r == null || !mounted) return;
    await _openDiff(
      title: 'Constraints & trade-offs — preview',
      result: SimulationResult(
          days: r.days,
          summary: r.feasible
              ? 'Feasible with your constraints.'
              : 'Conflicts found.',
          dropped: r.dropped,
          conflicts: r.violations),
      onApply: () => _applyPlan(r.days, 'Constraints applied',
          DecisionType.constraintsApplied),
      trip: trip,
    );
  }

  Widget _slider(String label, int value, void Function(int) onChanged) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(label, style: const TextStyle(fontSize: 12.5)),
        Slider(
            value: value.toDouble(),
            min: 0,
            max: 100,
            divisions: 10,
            label: '$value',
            onChanged: (double v) => onChanged(v.round())),
      ]);

  Future<void> _openGraph(TripPlan trip) async {
    final DependencyGraph g = TripIntelligenceEngine.dependencyGraph(_plan);
    int? selected;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setM) =>
            SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.75,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              const Text('Dependency graph',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const Text(
                  'Each stop depends on the previous one (its time assumes '
                  'the earlier one happened). Tap a stop to see what slips '
                  'if it runs late.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              for (int i = 0; i < g.nodes.length; i++)
                ListTile(
                  dense: true,
                  selected: selected == i,
                  leading: Text('D${g.nodes[i].dayIndex + 1}',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w800)),
                  title: Text(g.nodes[i].label,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text(
                      g.nodes[i].startMin == null
                          ? 'time not set'
                          : 'starts ${TripIntelligenceEngine.minToTime(g.nodes[i].startMin!)}',
                      style: const TextStyle(fontSize: 11)),
                  onTap: () => setM(() => selected = i),
                  trailing: selected == i
                      ? const Icon(Icons.south, size: 16)
                      : null,
                ),
              if (selected != null) ...<Widget>[
                const Divider(),
                Text('If "${g.nodes[selected!].label}" runs 45 min late:',
                    style: const TextStyle(fontWeight: FontWeight.w800,
                        fontSize: 13)),
                const SizedBox(height: 4),
                for (final int a in g.affectedBy(selected, 45))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                        '• ${g.nodes[a].label} (day '
                        '${g.nodes[a].dayIndex + 1}) slides later',
                        style: const TextStyle(fontSize: 12,
                            color: AppTheme.warning)),
                  ),
                if (g.affectedBy(selected, 45).isEmpty)
                  const Text('Nothing downstream in this day.',
                      style: TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openReplay() async {
    await _replay.load();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: _replay.records.isEmpty
            ? const Center(
                child: Text(
                    'No decisions recorded yet. Apply a simulation, recovery '
                    'or constraint plan and it will be recorded here — real '
                    'actions only, never invented.'))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Row(children: <Widget>[
                    const Expanded(
                        child: Text('Decision replay',
                            style: TextStyle(fontWeight: FontWeight.w800))),
                    TextButton(
                        onPressed: () async {
                          await _replay.clear();
                          Navigator.pop(ctx);
                        },
                        child: const Text('Clear all')),
                  ]),
                  for (final DecisionRecord r in _replay.records)
                    ListTile(
                      dense: true,
                      leading: Icon(_replayIcon(r.type), size: 18),
                      title: Text(r.title,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                          '${r.detail}\n'
                          '${r.at.day}/${r.at.month} '
                          '${r.at.hour}:${r.at.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(fontSize: 11)),
                      isThreeLine: true,
                    ),
                ],
              ),
      ),
    );
    if (mounted) setState(() {});
  }

  IconData _replayIcon(DecisionType t) => switch (t) {
        DecisionType.scenarioApplied => Icons.timelapse,
        DecisionType.constraintsApplied => Icons.tune,
        DecisionType.recoveryApplied => Icons.healing,
        DecisionType.tripEdited => Icons.edit,
        DecisionType.stopSkipped => Icons.skip_next,
      };

  Future<void> _openWhyNot(TripPlan trip) async {
    final TextEditingController ctrl = TextEditingController();
    final String? q = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Why not this place?'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
              hintText: 'Place name — searched with your real GPS + OSRM'),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Check')),
        ],
      ),
    );
    ctrl.dispose();
    if (q == null || q.isEmpty || !mounted) return;
    setState(() {});
    if (!mounted) return;
    // Real search + real route from the CURRENT position (existing services).
    final Position? me = await _c.locationService.currentPosition();
    if (!mounted) return;
    if (me == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Location unavailable — enable GPS to evaluate a '
              'place against your remaining day.')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Checking route and timing…')));
    try {
      final List<Place> results = await _c.placesRepository.suggest(q,
          location: LatLng(me.latitude, me.longitude), limit: 1);
      if (!mounted) return;
      if (results.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('No place matched "$q" — nothing to evaluate.')));
        return;
      }
      final Place p = results.first;
      final RouteInfo? route = await _c.placesRepository.route(
        LatLng(me.latitude, me.longitude),
        LatLng(p.lat, p.lng),
      );
      final int nowMin = DateTime.now().hour * 60 + DateTime.now().minute;
      final int? legMin = route == null
          ? null
          : (route.durationSeconds / 60).round();
      final List<WhyNotReason> reasons = TripIntelligenceEngine.whyNot(
        placeName: p.name,
        legMinutes: legMin,
        remainingMinutes: 21 * 60 - nowMin,
        dayEndMin: 21 * 60,
        nowMin: nowMin,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (BuildContext ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text('Why not "${p.name}"?',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              if (p.contextLine.isNotEmpty)
                Text(p.contextLine, style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(TripIntelligenceEngine.timeToEnjoyment(legMin),
                  style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 8),
              for (final WhyNotReason r in reasons)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(Icons.info, size: 15),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text('${r.reason} — ${r.detail}',
                              style: const TextStyle(fontSize: 12.5))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not check right now (search/route service unreachable) '
              '— try again when online.')));
    }
  }

  // ---------------- shared apply/diff ----------------

  Future<void> _openDiff({
    required String title,
    required SimulationResult result,
    required Future<void> Function() onApply,
    required TripPlan trip,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(title,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Nothing is changed until you press Apply.',
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 10),
            Text(result.summary,
                style: const TextStyle(fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (result.dropped.isNotEmpty) ...<Widget>[
              const Text('No longer fits:',
                  style: TextStyle(fontWeight: FontWeight.w700,
                      fontSize: 13)),
              for (final String d in result.dropped)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $d',
                      style: const TextStyle(fontSize: 12,
                          color: AppTheme.danger)),
                ),
              const SizedBox(height: 8),
            ],
            if (result.conflicts.isNotEmpty) ...<Widget>[
              const Text('Timing conflicts:',
                  style: TextStyle(fontWeight: FontWeight.w700,
                      fontSize: 13)),
              for (final String c in result.conflicts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $c',
                      style: const TextStyle(fontSize: 12,
                          color: AppTheme.warning)),
                ),
              const SizedBox(height: 8),
            ],
            for (int d = 0; d < result.days.length; d++) ...<Widget>[
              Text('Day ${result.days[d].day}: ${result.days[d].title}',
                  style: const TextStyle(fontWeight: FontWeight.w800,
                      fontSize: 13)),
              for (final ItineraryItem i in result.days[d].items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('${i.time}  ${i.title}',
                      style: const TextStyle(fontSize: 12.5)),
                ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 12),
            Row(children: <Widget>[
              Expanded(
                child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Discard')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await onApply();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Apply to my trip'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Writes the simulated plan into the EXISTING TripPlanStore (no
  /// duplication — same trip, updated plan) and records the decision.
  Future<void> _applyPlan(
      List<ItineraryDay> days, String title, DecisionType type) async {
    final TripPlan trip = _trip!;
    final TripPlan updated = TripPlan(
      id: trip.id,
      destination: trip.destination,
      lat: trip.lat,
      lng: trip.lng,
      startDate: trip.startDate,
      days: trip.days,
      budget: trip.budget,
      travelStyle: trip.travelStyle,
      transport: trip.transport,
      partySize: trip.partySize,
      interests: trip.interests,
      plan: days,
      createdAt: trip.createdAt,
    );
    await _c.tripPlanStore.update(updated);
    await _replay.add(
      type: type,
      title: title,
      detail: '${trip.destination}: plan updated via Travel Intelligence.',
      tripId: trip.id,
    );
    _c.settings.recordBehaviour(
        packedness: days.fold<int>(0, (int a, ItineraryDay d) => a + d.items.length) /
            (days.isEmpty ? 1 : days.length));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$title — your trip plan was updated.')));
    }
  }
}
