import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/trip_plan.dart';
import '../travel_automation_engine.dart';
import '../travel_automation_service.dart';

class TravelAutomationScreen extends StatefulWidget {
  const TravelAutomationScreen({super.key});

  @override
  State<TravelAutomationScreen> createState() =>
      _TravelAutomationScreenState();
}

class _TravelAutomationScreenState extends State<TravelAutomationScreen> {
  AppContainer get _c => AppScope.of(context);
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    await _c.tripPlanStore.loadFor(uid);
    await _c.travelAutomation.load(uid);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final TripPlan? trip = _c.tripPlanStore.active;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.auto_awesome_motion_outlined),
            SizedBox(width: 9),
            Text('Travel Automation'),
          ],
        ),
      ),
      body: !_c.tripPlanStore.loaded
          ? const LoadingView(message: 'Loading your automation workspace…')
          : trip == null
              ? EmptyState(
                  icon: Icons.event_busy_outlined,
                  title: 'Create a trip first',
                  message: 'Automations use a real trip date and duration so '
                      'notifications are scheduled honestly—not at random.',
                  actionLabel: 'Create trip plan',
                  onAction: () => context.push('/planner'),
                )
              : ListenableBuilder(
                  listenable: _c.travelAutomation,
                  builder: (BuildContext context, Widget? child) =>
                      _content(trip),
                ),
    );
  }

  Widget _content(TripPlan trip) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
      children: <Widget>[
        _tripHeader(trip),
        const SizedBox(height: 8),
        Text(
          'Enable only what helps. Every enabled card schedules real Android '
          'notifications from this trip’s date; nothing is marked automatic '
          'unless the OS accepted at least one schedule.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        _phase('Before the trip', AutomationPhase.beforeTrip),
        _phase('During the trip', AutomationPhase.duringTrip),
        _phase('After the trip', AutomationPhase.afterTrip),
      ],
    );
  }

  Widget _tripHeader(TripPlan trip) {
    final int enabled = _c.travelAutomation.enabled.length;
    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: <Color>[AppTheme.brandStart, AppTheme.brandEnd],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.bolt, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(trip.destination,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge),
                Text(
                  '${DateFormat('d MMM yyyy').format(trip.startDate)} · '
                  '${trip.days} day${trip.days == 1 ? '' : 's'} · '
                  '$enabled active',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open trip plans',
            onPressed: () => context.push('/planner'),
            icon: const Icon(Icons.edit_calendar_outlined),
          ),
        ],
      ),
    );
  }

  Widget _phase(String title, AutomationPhase phase) {
    final List<AutomationDefinition> definitions = TravelAutomationEngine
        .definitions
        .where((AutomationDefinition d) => d.phase == phase)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHeader(title: title),
        for (final AutomationDefinition definition in definitions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _automationCard(definition),
          ),
      ],
    );
  }

  Widget _automationCard(AutomationDefinition definition) {
    final TravelAutomationService service = _c.travelAutomation;
    final bool enabled = service.isEnabled(definition.kind);
    final List<DateTime> times = service
        .timesFor(definition.kind)
        .where((DateTime d) => d.isAfter(DateTime.now()))
        .toList();
    final IconData icon = _iconFor(definition.kind);
    final String schedule = enabled
        ? times.isEmpty
            ? 'Enabled · schedule elapsed'
            : '${times.length} scheduled · next ${DateFormat('d MMM, h:mm a').format(times.first)}'
        : 'Off';
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: (enabled ? AppTheme.success : AppTheme.brandStart)
                  .withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon,
                color: enabled ? AppTheme.success : AppTheme.brandStart,
                size: 22),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(definition.title,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(definition.description,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                Text(schedule,
                    style: TextStyle(
                      color: enabled
                          ? AppTheme.success
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: service.busy
                ? null
                : (bool value) => _toggle(definition.kind, value),
          ),
        ],
      ),
    );
  }

  Future<void> _toggle(TravelAutomationKind kind, bool value) async {
    if (!value) {
      await _c.travelAutomation.disable(kind);
      return;
    }
    final AutomationEnableResult result =
        await _c.travelAutomation.enable(kind);
    if (!mounted || result == AutomationEnableResult.enabled) return;
    final String message = switch (result) {
      AutomationEnableResult.noTrip => 'Create or select an active trip first.',
      AutomationEnableResult.noFutureEvents =>
        'This automation has no future event for the current trip dates.',
      AutomationEnableResult.permissionDenied =>
        'Notification permission is required for travel automation.',
      AutomationEnableResult.enabled => '',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  IconData _iconFor(TravelAutomationKind kind) =>
      switch (kind) {
        TravelAutomationKind.packing => Icons.luggage_outlined,
        TravelAutomationKind.documents => Icons.folder_copy_outlined,
        TravelAutomationKind.bookingReview => Icons.fact_check_outlined,
        TravelAutomationKind.weatherCheck => Icons.cloud_outlined,
        TravelAutomationKind.vehicleReadiness => Icons.car_repair_outlined,
        TravelAutomationKind.departureBrief => Icons.wb_sunny_outlined,
        TravelAutomationKind.morningBrief => Icons.calendar_view_day_outlined,
        TravelAutomationKind.hotelCheckIn => Icons.hotel_outlined,
        TravelAutomationKind.essentialsCheck => Icons.local_pharmacy_outlined,
        TravelAutomationKind.hydration => Icons.water_drop_outlined,
        TravelAutomationKind.budgetPulse => Icons.savings_outlined,
        TravelAutomationKind.returnBeforeDark => Icons.nights_stay_outlined,
        TravelAutomationKind.safetyCheckIn => Icons.health_and_safety_outlined,
        TravelAutomationKind.photoBackup => Icons.backup_outlined,
        TravelAutomationKind.tripWrap => Icons.task_alt,
      };
}
