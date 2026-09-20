import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/state_views.dart';
import '../autopilot_engine.dart';
import '../autopilot_models.dart';
import '../autopilot_service.dart';

/// 🧭 TRAVEL AUTOPILOT — "Tell us what you want to do. We'll help you
/// figure out what to do next."
///
/// Works with ZERO itinerary: current location + available time is enough.
/// Every recommendation is a REAL nearby place with real travel time,
/// real clock math and honest unknowns ("Opening hours unavailable").
class AutopilotScreen extends StatefulWidget {
  const AutopilotScreen({super.key});

  @override
  State<AutopilotScreen> createState() => _AutopilotScreenState();
}

class _AutopilotScreenState extends State<AutopilotScreen> {
  AppContainer get _c => AppScope.of(context);
  AutopilotService get _svc => _c.autopilotService;

  int _step = 0; // wizard step
  final Set<AutopilotInterest> _picked = <AutopilotInterest>{};
  final TextEditingController _text = TextEditingController();
  int? _minutes;
  final TextEditingController _budget = TextEditingController();
  final TextEditingController _maxTravel = TextEditingController();
  AutopilotMode _mode = AutopilotMode.drive;
  AutopilotGroup _group = AutopilotGroup.solo;
  final TextEditingController _endName = TextEditingController();

  int _debugTaps = 0;
  bool _showArrivalSheet = false;
  int _lastVisitedCount = 0;

  @override
  void initState() {
    super.initState();
    _svc.ensureRestored();
    _svc.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _svc.removeListener(_onServiceChanged);
    _text.dispose();
    _budget.dispose();
    _maxTravel.dispose();
    _endName.dispose();
    super.dispose();
  }

  /// Celebrate arrival exactly once per newly visited stop.
  void _onServiceChanged() {
    final AutopilotSession? session = _svc.session;
    if (session == null) return;
    final int visited =
        session.stopsWithStatus(AutopilotStopStatus.visited).length;
    final bool increased = visited > _lastVisitedCount;
    _lastVisitedCount = visited;
    if (increased && !_showArrivalSheet && mounted) {
      setState(() => _showArrivalSheet = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _arrivalSheet());
    }
  }

  /// "✅ You've arrived — want to continue?"
  Future<void> _arrivalSheet() async {
    final int left = _svc.minutesLeft();
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text("✅ You've arrived!",
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
              Text(
                  'You have about ${AutopilotEngine.formatDurationLabel(left)} left.',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _svc.whatNext();
                  },
                  icon: const Icon(Icons.upcoming),
                  label: const Text('SHOW NEXT'),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('STAY HERE')),
              ),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _svc.stopAutopilot();
                      if (mounted) setState(() => _step = 0);
                    },
                    child: const Text('END AUTOPILOT')),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() => _showArrivalSheet = false);
  }

  Future<void> _generate({bool autoPlan = false}) async {
    final AutopilotBrief brief = AutopilotBrief(
      interests: _picked,
      availableMinutes: _minutes,
      budgetRs: int.tryParse(_budget.text.trim()),
      maxTravelMinutes: int.tryParse(_maxTravel.text.trim()),
      mode: _mode,
      group: _group,
      endName: _endName.text.trim().isEmpty ? null : _endName.text.trim(),
      freeText: _text.text.trim().isEmpty ? null : _text.text.trim(),
    );
    AutopilotBrief effective = brief;
    if (brief.freeText != null && brief.freeText!.isNotEmpty) {
      effective = AutopilotEngine.parseBrief(brief.freeText!, base: brief);
    }
    await _svc.start(effective);
    if (!mounted) return;
    if (autoPlan && _svc.suggestions.isNotEmpty) {
      _svc.generatePlan();
    }
    setState(() => _step = 3);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _svc,
      builder: (BuildContext context, _) {
        final bool inSession = _svc.session != null;
        return PopScope(
          canPop: !inSession,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (didPop) return;
            // Leaving the screen keeps the session alive (background-safe).
            context.go('/home');
          },
          child: Scaffold(
            appBar: AppBar(
              title: GestureDetector(
                onTap: () {
                  _debugTaps++;
                  if (_debugTaps == 7 && !_svc.debugUnlocked) {
                    setState(() => _svc.debugUnlocked = true);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Developer controls enabled')));
                  }
                },
                child: const Text('🧭 Travel Autopilot'),
              ),
            ),
            body: _svc.session != null
                ? _dashboard()
                : IndexedStack(
                    index: _step.clamp(0, 3),
                    children: <Widget>[
                      _stepInterests(),
                      _stepTime(),
                      _stepOptions(),
                      _stepResults(),
                    ],
                  ),
            bottomNavigationBar: _svc.session != null ? _stopBar() : null,
          ),
        );
      },
    );
  }

  // ============================================================
  // WIZARD
  // ============================================================

  Widget _stepInterests() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text('What are you looking to do?',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('Pick any — or just type it. You can also skip this entirely.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final AutopilotInterest i in AutopilotInterest.values)
              FilterChip(
                label: Text('${i.emoji} ${i.label}'),
                selected: _picked.contains(i),
                onSelected: (bool on) => setState(() =>
                    on ? _picked.add(i) : _picked.remove(i)),
              ),
          ],
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _text,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Type what I want',
            hintText:
                '"I want to explore nearby places and have good food."',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            if (_text.text.trim().isNotEmpty) {
              final AutopilotBrief parsed =
                  AutopilotEngine.parseBrief(_text.text);
              setState(() {
                _picked.addAll(parsed.interests);
                _minutes ??= parsed.availableMinutes;
                if (parsed.budgetRs != null) {
                  _budget.text = parsed.budgetRs.toString();
                }
              });
              if (_minutes != null) {
                await _generate();
              } else if (mounted) {
                setState(() => _step = 1);
              }
            } else if (mounted) {
              setState(() => _step = 1);
            }
          },
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Tell me from my text'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => setState(() => _step = 1),
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Next: how much time?'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () async {
            // "WHAT SHOULD I DO NOW?" — no interests needed at all.
            await _svc.start(const AutopilotBrief());
            if (mounted) setState(() => _step = 3);
          },
          icon: const Icon(Icons.explore),
          label: const Text('WHAT SHOULD I DO NOW?'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _stepTime() {
    final List<(String, int?)> choices = <(String, int?)>[
      ('30 minutes', 30),
      ('1 hour', 60),
      ('2 hours', 120),
      ('4 hours', 240),
      ('All day', 600),
      ('Custom', null),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text('How much time do you have?',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final (String, int?) c in choices)
              ChoiceChip(
                label: Text(c.$1),
                selected:
                    c.$2 != null && _minutes == c.$2,
                onSelected: (bool _) => setState(() {
                  if (c.$2 == null) {
                    _askCustomMinutes();
                  } else {
                    _minutes = c.$2;
                  }
                }),
              ),
          ],
        ),
        if (_minutes != null) ...<Widget>[
          const SizedBox(height: 8),
          Text('About ${AutopilotEngine.formatDurationLabel(_minutes!)}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _minutes == null
              ? () => _askCustomMinutes()
              : () => setState(() => _step = 2),
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Next: options (all optional)'),
        ),
        TextButton(
          onPressed: () => setState(() => _step = 0),
          child: const Text('Back'),
        ),
      ],
    );
  }

  Future<void> _askCustomMinutes() async {
    final TextEditingController c = TextEditingController();
    final int? result = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Custom time'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Minutes', hintText: 'e.g. 90'),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, int.tryParse(c.text.trim())),
              child: const Text('Set')),
        ],
      ),
    );
    if (result != null && result > 0) {
      setState(() => _minutes = result);
    }
  }

  Widget _stepOptions() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text('Optional extras',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Everything here is optional — skip anything.'),
        const SizedBox(height: 14),
        TextField(
          controller: _budget,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Budget (₹) — optional',
            hintText: '1000',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _maxTravel,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: "Don't take me more than (minutes) — optional",
            hintText: '20',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        SegmentedButton<AutopilotMode>(
          segments: const <ButtonSegment<AutopilotMode>>[
            ButtonSegment<AutopilotMode>(
                value: AutopilotMode.drive,
                icon: Icon(Icons.directions_car), label: Text('Driving')),
            ButtonSegment<AutopilotMode>(
                value: AutopilotMode.bike,
                icon: Icon(Icons.two_wheeler), label: Text('Bike')),
            ButtonSegment<AutopilotMode>(
                value: AutopilotMode.walk,
                icon: Icon(Icons.directions_walk), label: Text('Walking')),
          ],
          selected: <AutopilotMode>{_mode},
          onSelectionChanged: (Set<AutopilotMode> s) =>
              setState(() => _mode = s.first),
        ),
        const SizedBox(height: 10),
        SegmentedButton<AutopilotGroup>(
          segments: const <ButtonSegment<AutopilotGroup>>[
            ButtonSegment<AutopilotGroup>(
                value: AutopilotGroup.solo, label: Text('👤 Solo')),
            ButtonSegment<AutopilotGroup>(
                value: AutopilotGroup.family, label: Text('👨‍👩‍👧 Family')),
            ButtonSegment<AutopilotGroup>(
                value: AutopilotGroup.friends, label: Text('👫 Friends')),
          ],
          selected: <AutopilotGroup>{_group},
          onSelectionChanged: (Set<AutopilotGroup> s) =>
              setState(() => _group = s.first),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _endName,
          decoration: const InputDecoration(
            labelText: 'End destination (optional)',
            hintText: 'Return to hotel / starting point by …',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: () => _generate(),
          icon: const Icon(Icons.flash_on),
          label: const Text('GENERATE'),
        ),
        FilledButton.icon(
          onPressed: () => _generate(autoPlan: true),
          icon: const Icon(Icons.auto_mode),
          label: const Text('⚡ AUTO PLAN'),
        ),
        TextButton(
          onPressed: () => setState(() => _step = 1),
          child: const Text('Back'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ============================================================
  // RESULTS (recommendations / plan)
  // ============================================================

  Widget _stepResults() {
    if (_svc.loading) {
      return const LoadingView(message: 'Finding real places near you…');
    }
    if (_svc.error != null) {
      return _errorView();
    }
    final AutopilotPlan? plan = _svc.plan;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        Text('WHAT YOU CAN DO NOW',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800)),
        Text('📍 Based on your current location',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 10),
        if (plan != null) ...<Widget>[
          _planCard(plan),
          const SizedBox(height: 14),
        ],
        for (final AutopilotSuggestion s in _svc.suggestions)
          _suggestionCard(s),
        if (_svc.suggestions.isEmpty) ...<Widget>[
          const SizedBox(height: 8),
          const EmptyState(
            icon: Icons.search_off,
            title: 'No suitable places found nearby.',
            message: 'The open places were collected around your current '
                'position, but nothing left passed the filters — opening '
                'hours right now, your interests, or the time left in the '
                'session. Change the plan (more time / another interest) or '
                'move somewhere with more coverage and refresh.',
          ),
        ],
        _notPracticalSection(),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _svc.recompute(),
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh options'),
        ),
        const SizedBox(height: 8),
        if (_svc.brief.budgetRs != null) _budgetCard(),
        _debugPanel(),
      ],
    );
  }

  Widget _errorView() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (_svc.error == AutopilotErrorKind.locationUnavailable) ...<Widget>[
            const Icon(Icons.location_off, size: 48, color: AppTheme.danger),
            const SizedBox(height: 12),
            Text('📍 Your current location is unavailable.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _svc.recompute(),
              icon: const Icon(Icons.refresh),
              label: const Text('TRY AGAIN'),
            ),
            OutlinedButton.icon(
              onPressed: () => context.go('/map'),
              icon: const Icon(Icons.map),
              label: const Text('SEARCH A LOCATION MANUALLY'),
            ),
          ] else ...<Widget>[
            const Icon(Icons.cloud_off, size: 48, color: AppTheme.warning),
            const SizedBox(height: 12),
            Text(_svc.errorMessage ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _svc.recompute(),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _suggestionCard(AutopilotSuggestion s) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(s.emoji,
                    style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final String r in s.reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('· '),
                    Expanded(
                        child: Text(r,
                            style:
                                Theme.of(context).textTheme.bodySmall)),
                  ],
                ),
              ),
            if (s.feeLikely)
              const Text('Entry fee likely — price unavailable',
                  style: TextStyle(fontSize: 11, color: AppTheme.warning)),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _goHere(s),
                    icon: const Icon(Icons.navigation, size: 16),
                    label: const Text('GO HERE'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Skip this place',
                  onPressed: () => _svc.skip(s),
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _goHere(AutopilotSuggestion s) async {
    _svc.choose(s);
    if (!mounted) return;
    await context.push(
        '/trip/live?lat=${s.lat}&lng=${s.lng}&name=${Uri.encodeComponent(s.name)}');
  }

  Widget _notPracticalSection() {
    if (_svc.notPractical.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
          'Not practical right now (${_svc.notPractical.length})',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: AppTheme.danger, fontWeight: FontWeight.w700)),
      subtitle: const Text('Real reasons — closing soon / does not fit',
          style: TextStyle(fontSize: 11)),
      children: <Widget>[
        for (final (AutopilotSuggestion, String) item in _svc.notPractical)
          ListTile(
            dense: true,
            leading: Text(item.$1.emoji),
            title: Text(item.$1.name,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('🔴 ${item.$2}'),
          ),
      ],
    );
  }

  Widget _budgetCard() {
    final int budget = _svc.brief.budgetRs ?? 0;
    // Honest transport estimate only — entry/food prices are NEVER invented.
    final int transport = _svc.suggestions.isEmpty
        ? 0
        : AutopilotEngine.transportEstimateRs(
            _svc.suggestions.first.distanceMeters * 2, _svc.brief.mode);
    return Card(
      margin: const EdgeInsets.only(top: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Budget: ₹$budget',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Transport (estimate): ₹$transport',
                style: Theme.of(context).textTheme.bodySmall),
            const Text('Food: price unavailable',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const Text('Entry: price unavailable',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(
                transport > 0
                    ? 'Remaining after transport (est.): ₹${budget - transport}'
                    : 'Price data is not available for these places.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _planCard(AutopilotPlan plan) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('⚡ AUTO PLAN',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (int i = 0; i < plan.steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: <Widget>[
                    Text('${i + 1}️⃣',
                        style: const TextStyle(fontSize: 15)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${plan.steps[i].suggestion.name} — '
                        '${plan.steps[i].travelMinutes} min travel, '
                        '${plan.steps[i].suggestion.visitMinutes} min visit',
                      ),
                    ),
                  ],
                ),
              ),
            Text(
                'Estimated total: ~${AutopilotEngine.formatDurationLabel(plan.totalMinutes)}',
                style: Theme.of(context).textTheme.bodySmall),
            Text(
                plan.totalMinutes <= (_minutes ?? 120)
                    ? '🟢 Fits your available time'
                    : '🔴 Does not fit your available time',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await _svc.startPlan();
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('START THIS PLAN'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                    onPressed: () =>
                        setState(() => _svc.generatePlan()),
                    child: const Text('REGENERATE')),
              ],
            ),
            TextButton(
                onPressed: () => setState(() => _step = 0),
                child: const Text('CHANGE')),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // DASHBOARD (active session)
  // ============================================================

  Widget _dashboard() {
    final AutopilotSession s = _svc.session!;
    final int left = _svc.minutesLeft();
    final AutopilotStop? cur = _svc.currentStop;
    final AutopilotStop? next = s.stops
        .where((AutopilotStop st) => st.status == AutopilotStopStatus.proposed)
        .firstOrNull;
    final AutopilotStop? shownNext = cur ?? next;
    final AutopilotRecovery? rec = _svc.recovery;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        _statusCard(left, shownNext),
        if (rec != null) _recoveryCard(rec),
        const SizedBox(height: 12),
        _journeyCard(s),
        const SizedBox(height: 12),
        if (cur != null) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await context.push(
                        '/trip/live?lat=${cur.lat}&lng=${cur.lng}&name=${Uri.encodeComponent(cur.name)}');
                  },
                  icon: const Icon(Icons.navigation),
                  label: const Text('TAKE ME THERE'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _svc.whatNext(),
                icon: const Icon(Icons.upcoming),
                label: const Text('WHAT NEXT?'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _svc.fixMyTrip(),
                icon: const Icon(Icons.healing),
                label: const Text('FIX MY TRIP'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _changePlan,
                icon: const Icon(Icons.change_circle),
                label: const Text('CHANGE PLAN'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _breakFlow,
                icon: const Icon(Icons.self_improvement),
                label: const Text('😴 BREAK'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('NEXT BEST OPTIONS',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        // The header used to render on its own with nothing under it — a
        // section that looked simply broken (reported from the live app while
        // the dataset was still loading or came back empty). Every state now
        // says what is happening and offers the one action that helps.
        if (_svc.suggestions.isEmpty)
          _nextBestPlaceholder()
        else
          for (final AutopilotSuggestion sg in _svc.suggestions.take(8))
            _suggestionCard(sg),
        _notPracticalSection(),
        _budgetCardIfExists(),
        _debugPanel(),
      ],
    );
  }

  /// Loading / empty / error states for "NEXT BEST OPTIONS".
  Widget _nextBestPlaceholder() {
    final Widget child;
    if (_svc.loading) {
      child = const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LinearProgressIndicator(),
          SizedBox(height: 10),
          Text('Collecting open places around you…',
              style: TextStyle(fontSize: 12.5)),
        ],
      );
    } else if (_svc.error != null) {
      child = ErrorState(
        message: _svc.errorMessage ??
            'Autopilot could not read the nearby dataset.',
        onRetry: () => _svc.recompute(),
      );
    } else {
      child = EmptyState(
        icon: Icons.place_outlined,
        title: 'Nothing else practical right now',
        message: _svc.atDestination
            ? 'Everything nearby is already visited, closed, or too far for '
                  'this leg. Change the plan (or your budget / time limit) and '
                  'Autopilot will look again.'
            : 'No suitable places were found near the destination yet. It can '
                  'take a minute for the nearby data to arrive — scan again.',
        actionLabel: 'SCAN AGAIN',
        onAction: () => _svc.recompute(),
      );
    }
    return child;
  }

  Widget _budgetCardIfExists() =>
      _svc.brief.budgetRs == null ? const SizedBox.shrink() : _budgetCard();

  Widget _statusCard(int left, AutopilotStop? focus) {
    final bool onTrack = left > 20;
    return Card(
      color: onTrack
          ? AppTheme.success.withValues(alpha: 0.10)
          : AppTheme.danger.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(onTrack ? '🟢 On Track' : '🔴 Running behind',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const Spacer(),
                Text('⏳ ${AutopilotEngine.formatDurationLabel(left)} left',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 6),
            if (_svc.destinationName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _svc.atDestination
                      ? '🎯 ${_svc.destinationName} — planning around '
                          'your current position'
                      : '🎯 ${_svc.destinationName} · '
                          '${GeoUtils.formatDistance(_svc.destinationDistanceMeters)} '
                          'from you — suggestions come from there',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            Text(
                'CURRENT: ${focus == null ? '📍 Pick your first stop' : '📍 ${focus.name}'}',
                style: Theme.of(context).textTheme.bodyMedium),
            if (focus != null && focus.category.isNotEmpty)
              Text('Estimated visit: ${focus.visitMinutes} min',
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _journeyCard(AutopilotSession s) {
    final List<AutopilotStop> journey = s.stops
        .where((AutopilotStop st) =>
            st.status == AutopilotStopStatus.visited ||
            st.status == AutopilotStopStatus.accepted ||
            st.status == AutopilotStopStatus.proposed)
        .toList();
    if (journey.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text("TODAY'S AUTOPILOT JOURNEY",
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (int i = 0; i < journey.length; i++)
              Row(
                children: <Widget>[
                  Text('${i + 1}.'),
                  const SizedBox(width: 6),
                  Text(journey[i].status == AutopilotStopStatus.visited
                      ? '✅'
                      : journey[i].status == AutopilotStopStatus.accepted
                          ? '▶️'
                          : '⬜'),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      journey[i].name == 'Break'
                          ? '😴 Break (30 min)'
                          : journey[i].name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (journey[i].status == AutopilotStopStatus.proposed)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Remove from plan',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => _svc.removeStop(journey[i].id),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _recoveryCard(AutopilotRecovery rec) {
    return Card(
      color: AppTheme.warning.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('🛟 YOUR PLAN HAS CHANGED',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const Text('You are running behind schedule.',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            for (final (AutopilotStop, String) d in rec.drop)
              Text('Skip ${d.$1.name} — ${d.$2}',
                  style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton(
                      onPressed: () => _svc.applyRecovery(),
                      child: const Text('APPLY')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                      onPressed: _svc.discardRecovery,
                      child: const Text('KEEP ORIGINAL')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.danger,
              side: const BorderSide(color: AppTheme.danger),
            ),
            onPressed: () async {
              final bool? confirm = await showDialog<bool>(
                context: context,
                builder: (BuildContext ctx) => AlertDialog(
                  title: const Text('Stop Autopilot?'),
                  content: const Text(
                      'Your journey and remaining time will be cleared.'),
                  actions: <Widget>[
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Stop')),
                  ],
                ),
              );
              if (confirm == true) {
                await _svc.stopAutopilot();
                if (mounted) setState(() => _step = 0);
              }
            },
            icon: const Icon(Icons.stop_circle),
            label: const Text('STOP AUTOPILOT'),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // Actions
  // ============================================================

  Future<void> _changePlan() async {
    final Set<AutopilotInterest> picked = <AutopilotInterest>{..._svc.brief.interests};
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setSheet) =>
            Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text("I don't want… / I want…",
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const Text(
                  'Pick new interests — completed stops stay untouched.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final AutopilotInterest i in AutopilotInterest.values)
                    FilterChip(
                      label: Text('${i.emoji} ${i.label}'),
                      selected: picked.contains(i),
                      onSelected: (bool on) => setSheet(() =>
                          on ? picked.add(i) : picked.remove(i)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Recalculate future options'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked.isNotEmpty) {
      await _svc.changeInterests(picked);
    }
  }

  Future<void> _breakFlow() async {
    final List<AutopilotSuggestion> options = _svc.breakOptions();
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                  'You have ${AutopilotEngine.formatDurationLabel(_svc.minutesLeft())} left.',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const Text('Take a 30-minute break?',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              for (final AutopilotSuggestion s in options)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text(s.emoji),
                  title: Text(s.name),
                  subtitle: Text(
                      '~${s.travelMinutes} min away · ${s.reasons.first}',
                      style: const TextStyle(fontSize: 11)),
                  trailing: TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _goHere(s);
                      },
                      child: const Text('GO')),
                ),
              if (options.isEmpty)
                const Text('No cafe/park found within 20 minutes.'),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await _svc.takeBreak();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.timer),
                      label: const Text('Take 30-min break here'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('CONTINUE AUTOPILOT')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // Developer-only controls (NEVER in normal production UI).
  // Unlock: 7 taps on the app bar title, or any debug build.
  // ============================================================

  Widget _debugPanel() {
    final bool visible = kDebugMode || _svc.debugUnlocked;
    if (!visible) return const SizedBox.shrink();
    return Card(
      color: const Color(0xFF101418),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('DEBUG (developer only)',
                style: TextStyle(
                    color: Color(0xFF9FE8A0),
                    fontWeight: FontWeight.w800,
                    fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton(
                    onPressed: () => _svc.debugSimulateArrival(),
                    child: const Text('Simulate arrival',
                        style: TextStyle(fontSize: 11))),
                OutlinedButton(
                    onPressed: () => _svc.debugSimulateDelay(45),
                    child: const Text('Simulate delay 45 min',
                        style: TextStyle(fontSize: 11))),
                OutlinedButton(
                    onPressed: () => _svc.debugSimulateSkip(),
                    child: const Text('Simulate skip',
                        style: TextStyle(fontSize: 11))),
                OutlinedButton(
                    onPressed: () => _svc.setDebugTimeOffset(Duration.zero),
                    child: const Text('Reset sim time',
                        style: TextStyle(fontSize: 11))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

extension on AutopilotSuggestion {
  String get emoji => switch (category) {
        'restaurant' || 'food' || 'fast_food' => '🍽️',
        'cafe' => '☕',
        'museum' => '🏛️',
        'park' => '🌳',
        'shopping' => '🛍️',
        'hotel' => '🏨',
        'attraction' => '📸',
        'fuel' => '⛽',
        _ => '📍',
      };
}
