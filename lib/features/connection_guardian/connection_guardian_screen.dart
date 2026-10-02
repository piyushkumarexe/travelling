import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/state/app_container.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_card.dart';
import 'connection_guardian_engine.dart';

class ConnectionGuardianScreen extends StatefulWidget {
  const ConnectionGuardianScreen({super.key});

  @override
  State<ConnectionGuardianScreen> createState() =>
      _ConnectionGuardianScreenState();
}

class _ConnectionGuardianScreenState extends State<ConnectionGuardianScreen> {
  static const String _prefix = 'connectionGuardian.v1.';
  ConnectionMode _incoming = ConnectionMode.train;
  ConnectionMode _outgoing = ConnectionMode.flight;
  TimeOfDay _arrival = TimeOfDay.now();
  TimeOfDay _departure = TimeOfDay.fromDateTime(
    DateTime.now().add(const Duration(hours: 2)),
  );
  double _delay = 0;
  bool _terminalChange = false;
  bool _baggage = false;
  bool _international = false;
  bool _mobility = false;
  bool _loaded = false;
  ConnectionAssessment? _assessment;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _incoming = _mode(p.getString('${_prefix}incoming')) ?? _incoming;
      _outgoing = _mode(p.getString('${_prefix}outgoing')) ?? _outgoing;
      _arrival = _time(p.getInt('${_prefix}arrival')) ?? _arrival;
      _departure = _time(p.getInt('${_prefix}departure')) ?? _departure;
      _delay = (p.getInt('${_prefix}delay') ?? 0).toDouble();
      _terminalChange = p.getBool('${_prefix}terminal') ?? false;
      _baggage = p.getBool('${_prefix}baggage') ?? false;
      _international = p.getBool('${_prefix}international') ?? false;
      _mobility = p.getBool('${_prefix}mobility') ?? false;
      _loaded = true;
    });
    _calculate(save: false);
  }

  ConnectionMode? _mode(String? value) {
    for (final ConnectionMode mode in ConnectionMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }

  TimeOfDay? _time(int? minuteOfDay) {
    if (minuteOfDay == null || minuteOfDay < 0 || minuteOfDay >= 1440) {
      return null;
    }
    return TimeOfDay(hour: minuteOfDay ~/ 60, minute: minuteOfDay % 60);
  }

  DateTime _dateFor(TimeOfDay time, {DateTime? after}) {
    final DateTime now = DateTime.now();
    DateTime value = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    if (after != null && !value.isAfter(after)) {
      value = value.add(const Duration(days: 1));
    } else if (after == null && value.isBefore(now.subtract(const Duration(hours: 1)))) {
      value = value.add(const Duration(days: 1));
    }
    return value;
  }

  Future<void> _calculate({bool save = true}) async {
    final DateTime arrival = _dateFor(_arrival);
    final DateTime departure = _dateFor(_departure, after: arrival);
    final ConnectionAssessment result = ConnectionGuardianEngine.assess(
      scheduledArrival: arrival,
      nextDeparture: departure,
      incomingMode: _incoming,
      outgoingMode: _outgoing,
      knownDelayMinutes: _delay.round(),
      terminalChange: _terminalChange,
      baggageRecheck: _baggage,
      internationalTransfer: _international,
      mobilityAssistance: _mobility,
    );
    if (mounted) setState(() => _assessment = result);
    if (!save) return;
    final SharedPreferences p = await SharedPreferences.getInstance();
    await Future.wait(<Future<bool>>[
      p.setString('${_prefix}incoming', _incoming.name),
      p.setString('${_prefix}outgoing', _outgoing.name),
      p.setInt('${_prefix}arrival', _arrival.hour * 60 + _arrival.minute),
      p.setInt('${_prefix}departure', _departure.hour * 60 + _departure.minute),
      p.setInt('${_prefix}delay', _delay.round()),
      p.setBool('${_prefix}terminal', _terminalChange),
      p.setBool('${_prefix}baggage', _baggage),
      p.setBool('${_prefix}international', _international),
      p.setBool('${_prefix}mobility', _mobility),
    ]);
  }

  Future<void> _pickTime(bool arrival) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: arrival ? _arrival : _departure,
    );
    if (picked == null || !mounted) return;
    setState(() => arrival ? _arrival = picked : _departure = picked);
    await _calculate();
  }

  Future<void> _scheduleReminder() async {
    final DateTime arrival = _dateFor(_arrival);
    final DateTime departure = _dateFor(_departure, after: arrival);
    final DateTime reminder = departure.subtract(const Duration(minutes: 45));
    if (!reminder.isAfter(DateTime.now())) {
      _message('The 45-minute reminder time has already passed.');
      return;
    }
    final bool ok = await AppScope.of(context).notificationService.schedule(
      id: 681201,
      title: 'Connection check',
      body: 'Verify delay, gate/platform and your transfer buffer now.',
      at: reminder,
      channel: 'general',
      payload: 'connection-guardian',
    );
    if (mounted) {
      _message(ok
          ? 'Connection reminder scheduled for ${TimeOfDay.fromDateTime(reminder).format(context)}.'
          : 'Could not schedule the reminder. Check notification permission.');
    }
  }

  void _message(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text)));

  Color _riskColor(ConnectionRisk risk) => switch (risk) {
        ConnectionRisk.safe => AppTheme.success,
        ConnectionRisk.tight => AppTheme.warning,
        ConnectionRisk.missed => AppTheme.danger,
      };

  String _riskTitle(ConnectionRisk risk) => switch (risk) {
        ConnectionRisk.safe => 'Connection has a workable buffer',
        ConnectionRisk.tight => 'Connection is tight',
        ConnectionRisk.missed => 'Connection is likely missed',
      };

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final ConnectionAssessment? result = _assessment;
    return Scaffold(
      appBar: AppBar(title: const Text('Connection Guardian')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          const AppCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.hub_outlined, size: 34),
                SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Check flight, train and bus transfers with explainable buffers. '
                    'Enter a known delay—Tourism never invents live status.',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          AppCard(
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: _modePicker('Arriving by', _incoming,
                        (ConnectionMode value) => _incoming = value)),
                    const SizedBox(width: 10),
                    Expanded(child: _modePicker('Connecting to', _outgoing,
                        (ConnectionMode value) => _outgoing = value)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(child: _timeButton('Scheduled arrival', _arrival, true)),
                    const SizedBox(width: 10),
                    Expanded(child: _timeButton('Next departure', _departure, false)),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    const Expanded(child: Text('Known delay')),
                    Text('${_delay.round()} min',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                Slider(
                  value: _delay,
                  min: 0,
                  max: 240,
                  divisions: 48,
                  label: '${_delay.round()} min',
                  onChanged: (double value) => setState(() => _delay = value),
                  onChangeEnd: (_) => _calculate(),
                ),
                _switch('Terminal or station change', _terminalChange,
                    (bool value) => _terminalChange = value),
                _switch('Collect and re-check baggage', _baggage,
                    (bool value) => _baggage = value),
                _switch('International immigration/security', _international,
                    (bool value) => _international = value),
                _switch('Mobility assistance required', _mobility,
                    (bool value) => _mobility = value),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _calculate,
                    icon: const Icon(Icons.analytics_outlined),
                    label: const Text('Assess connection'),
                  ),
                ),
              ],
            ),
          ),
          if (result != null) ...<Widget>[
            const SizedBox(height: 14),
            _resultCard(result),
          ],
        ],
      ),
    );
  }

  Widget _modePicker(String label, ConnectionMode value,
      ValueChanged<ConnectionMode> changed) => DropdownButtonFormField<ConnectionMode>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: <DropdownMenuItem<ConnectionMode>>[
          for (final ConnectionMode mode in ConnectionMode.values)
            DropdownMenuItem<ConnectionMode>(
              value: mode,
              child: Text(mode.name[0].toUpperCase() + mode.name.substring(1)),
            ),
        ],
        onChanged: (ConnectionMode? mode) {
          if (mode == null) return;
          setState(() => changed(mode));
          _calculate();
        },
      );

  Widget _timeButton(String label, TimeOfDay value, bool arrival) =>
      OutlinedButton(
        onPressed: () => _pickTime(arrival),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: <Widget>[
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 3),
              Text(value.format(context),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      );

  Widget _switch(String title, bool value, ValueChanged<bool> changed) =>
      SwitchListTile.adaptive(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        value: value,
        onChanged: (bool next) {
          setState(() => changed(next));
          _calculate();
        },
      );

  Widget _resultCard(ConnectionAssessment result) {
    final Color color = _riskColor(result.risk);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(result.risk == ConnectionRisk.safe
                  ? Icons.check_circle
                  : Icons.warning_amber_rounded, color: color, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_riskTitle(result.risk),
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: color, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              Chip(label: Text('${result.availableMinutes} min available')),
              Chip(label: Text('${result.requiredMinutes} min required')),
              Chip(label: Text('${result.marginMinutes} min margin')),
            ],
          ),
          const SizedBox(height: 14),
          Text('Why', style: Theme.of(context).textTheme.titleSmall),
          for (final String reason in result.reasons)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.add_circle_outline, size: 18),
              title: Text(reason),
            ),
          Text('Recommended actions',
              style: Theme.of(context).textTheme.titleSmall),
          for (final String action in result.actions)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.arrow_right, color: color),
              title: Text(action),
            ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _scheduleReminder,
                  icon: const Icon(Icons.alarm_add_outlined),
                  label: const Text('Set reminder'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => context.push('/booking'),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Official providers'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
