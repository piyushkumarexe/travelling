import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/local/fuel_log_store.dart';
import '../../../data/models/fuel_log.dart';
import '../../../data/models/profile.dart';

/// Vehicle — choose how you usually travel (Bike / Car / Auto), keep a fuel
/// log with accurate mileage (distance ÷ fuel consumed), set a service
/// reminder and estimate fuel cost for a planned trip.
///
/// The vehicle choice is saved to your profile. The fuel log and reminders
/// are stored on-device, so they work offline.
class VehicleScreen extends StatefulWidget {
  const VehicleScreen({super.key});

  @override
  State<VehicleScreen> createState() => _VehicleScreenState();
}

class _VehicleScreenState extends State<VehicleScreen> {
  AppContainer get _c => AppScope.of(context);

  Profile? _profile;
  bool _loading = true;
  bool _saving = false;
  StreamSubscription<Profile?>? _sub;

  static const List<(String, IconData, String)> _options =
      <(String, IconData, String)>[
    ('bike', Icons.two_wheeler, 'Bike'),
    ('car', Icons.directions_car, 'Car'),
    ('auto', Icons.electric_rickshaw, 'Auto'),
  ];

  @override
  void initState() {
    super.initState();
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid != null) {
      unawaited(_c.fuelLogStore.loadFor(uid));
      _c.fuelLogStore.addListener(_onFuelChanged);
      _sub = _c.profileRepository.watch(uid).listen((Profile? p) {
        if (mounted) {
          setState(() {
            _profile = p;
            _loading = false;
          });
        }
      }, onError: (Object _) {
        if (mounted) setState(() => _loading = false);
      });
    } else {
      _loading = false;
    }
  }

  void _onFuelChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _c.fuelLogStore.removeListener(_onFuelChanged);
    super.dispose();
  }

  Future<void> _select(String vehicle) async {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    if ((_profile?.vehicle ?? '') == vehicle) return;
    setState(() => _saving = true);
    try {
      await _c.profileRepository.setVehicle(uid, vehicle);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Vehicle saved: ${_label(vehicle)}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save vehicle: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _label(String vehicle) => switch (vehicle) {
        'bike' => 'Bike',
        'car' => 'Car',
        'auto' => 'Auto',
        _ => 'None',
      };

  // ---- Fuel log ----

  Future<void> _addFuel({FuelEntry? existing}) async {
    final TextEditingController odometer = TextEditingController(
        text: existing?.odometerKm.toStringAsFixed(0) ?? '');
    final TextEditingController liters = TextEditingController(
        text: existing?.liters.toStringAsFixed(2) ?? '');
    final TextEditingController cost =
        TextEditingController(text: existing?.cost.toStringAsFixed(2) ?? '');
    final TextEditingController notes =
        TextEditingController(text: existing?.notes ?? '');
    final TextEditingController parking =
        TextEditingController(text: existing?.parkingNote ?? '');
    DateTime date = existing?.date ?? DateTime.now();

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add fuel fill-up' : 'Edit fill-up'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: odometer,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Odometer reading (km)',
                    hintText: 'e.g. 24500',
                  ),
                ),
                TextField(
                  controller: liters,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Fuel added (litres)',
                  ),
                ),
                TextField(
                  controller: cost,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    prefixText: '₹ ',
                    labelText: 'Total cost',
                  ),
                ),
                TextField(
                  controller: parking,
                  decoration: const InputDecoration(
                    labelText: 'Parking note (optional)',
                  ),
                ),
                TextField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: 'Notes (optional)'),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: Text(Fmt.date(date)),
                  onTap: () async {
                    final DateTime? picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setDialogState(() => date = picked);
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final double odo = double.tryParse(odometer.text.trim()) ?? 0;
    final double lit = double.tryParse(liters.text.trim()) ?? 0;
    final double cst = double.tryParse(cost.text.trim()) ?? 0;
    if (odo <= 0 || lit <= 0 || cst <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Enter the odometer reading, litres and cost (all above 0).')),
        );
      }
      return;
    }
    final FuelEntry entry = FuelEntry(
      id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      date: date,
      odometerKm: odo,
      liters: lit,
      cost: cst,
      notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
      parkingNote: parking.text.trim().isEmpty ? null : parking.text.trim(),
    );
    if (existing == null) {
      await _c.fuelLogStore.add(entry);
    } else {
      await _c.fuelLogStore.update(entry);
    }
  }

  Future<void> _deleteFuel(FuelEntry e) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete fill-up?'),
        content: Text(
            '${e.liters.toStringAsFixed(2)} L at ${Fmt.date(e.date)} will be removed.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _c.fuelLogStore.remove(e.id);
  }

  Future<void> _setServiceReminder() async {
    final FuelLogStore store = _c.fuelLogStore;
    final TextEditingController odo = TextEditingController(
        text: store.nextServiceOdometerKm > 0
            ? store.nextServiceOdometerKm.toStringAsFixed(0)
            : '');
    final TextEditingController note =
        TextEditingController(text: store.serviceNote);
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Service reminder'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: odo,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Next service at odometer (km)',
                ),
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final double odoVal = double.tryParse(odo.text.trim()) ?? 0;
    await _c.fuelLogStore.setServiceReminder(odoVal, note.text.trim());
  }

  Future<void> _estimateTripFuel() async {
    final FuelLogStore store = _c.fuelLogStore;
    if (store.entries.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Log at least two fill-ups to estimate fuel for a trip.')),
        );
      }
      return;
    }
    final TextEditingController km = TextEditingController();
    final double? result = await showDialog<double>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Trip fuel estimate'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: km,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Trip distance (km)',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Uses your average mileage (${store.averageMileage!.toStringAsFixed(1)} km/l) '
              'and latest fuel price — an estimate only.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final double? d = double.tryParse(km.text.trim());
              Navigator.of(ctx).pop(d);
            },
            child: const Text('Estimate'),
          ),
        ],
      ),
    );
    if (result == null || result <= 0) return;
    final double? est = _c.fuelLogStore.estimateTripFuel(result);
    if (est == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Not enough data to estimate fuel cost for this trip.')),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Estimated fuel cost for ${result.toStringAsFixed(0)} km: '
              '₹${est.toStringAsFixed(0)} (estimate only)'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Vehicle')),
        body: const LoadingView(message: 'Loading…'),
      );
    }
    final String current = _profile?.vehicle ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'How do you usually travel?',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  'Your choice is saved to your profile and helps Tourism '
                  'give you realistic local price estimates.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final (String id, IconData icon, String label) in _options)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _optionCard(id, icon, label, current == id),
            ),
          const SizedBox(height: 8),
          _fuelSection(scheme),
          const SizedBox(height: 16),
          _serviceSection(scheme),
          const SizedBox(height: 16),
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                Icon(Icons.local_taxi, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Rapido, Uber & Ola price estimates are coming soon — '
                    'they will appear here under your chosen vehicle.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, {IconData? icon, VoidCallback? onTap}) {
    return Row(
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (onTap != null)
          TextButton(onPressed: onTap, child: const Text('Add')),
      ],
    );
  }

  Widget _fuelSection(ColorScheme scheme) {
    final FuelLogStore store = _c.fuelLogStore;
    final double? mileage = store.averageMileage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionTitle('Fuel log', icon: Icons.local_gas_station,
            onTap: () => _addFuel()),
        const SizedBox(height: 8),
        if (store.entries.isEmpty)
          AppCard(
            child: Column(
              children: <Widget>[
                Icon(Icons.local_gas_station,
                    size: 40, color: scheme.outline),
                const SizedBox(height: 10),
                Text(
                  'No fill-ups logged yet',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Log fuel fill-ups to track mileage, spending and estimate '
                  'fuel for trips.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: () => _addFuel(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add fill-up'),
                ),
              ],
            ),
          )
        else ...<Widget>[
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _stat(
                    'Avg mileage',
                    mileage != null ? '${mileage.toStringAsFixed(1)} km/l' : '—',
                  ),
                ),
                Expanded(
                  child: _stat(
                    'Total spent',
                    '₹${store.totalCost.toStringAsFixed(0)}',
                  ),
                ),
                TextButton.icon(
                  onPressed: _estimateTripFuel,
                  icon: const Icon(Icons.calculate, size: 16),
                  label: const Text('Trip fuel'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final FuelEntry e in store.orderedEntries.reversed)
            _fuelTile(e),
        ],
      ],
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
      ],
    );
  }

  Widget _fuelTile(FuelEntry e) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String parking =
        e.parkingNote != null ? ' · 🅿 ${e.parkingNote}' : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          leading: CircleAvatar(
            backgroundColor: scheme.primary.withValues(alpha: 0.10),
            child: Icon(Icons.local_gas_station,
                color: scheme.primary, size: 20),
          ),
          title: Text(
              '${e.odometerKm.toStringAsFixed(0)} km · ${e.liters.toStringAsFixed(2)} L'),
          subtitle: Text(
            '${Fmt.date(e.date)} · ₹${e.cost.toStringAsFixed(0)}'
            '${e.pricePerLiter > 0 ? ' (₹${e.pricePerLiter.toStringAsFixed(1)}/L)' : ''}'
            '$parking',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (String v) {
              if (v == 'edit') _addFuel(existing: e);
              if (v == 'delete') _deleteFuel(e);
            },
            itemBuilder: (BuildContext ctx) =>
                const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
              PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _serviceSection(ColorScheme scheme) {
    final FuelLogStore store = _c.fuelLogStore;
    final bool hasReminder = store.nextServiceOdometerKm > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionTitle('Service reminder', icon: Icons.build,
            onTap: _setServiceReminder),
        const SizedBox(height: 8),
        AppCard(
          padding: const EdgeInsets.all(14),
          child: hasReminder
              ? Row(
                  children: <Widget>[
                    Icon(Icons.notifications_active, color: AppTheme.warning),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Next service at ${store.nextServiceOdometerKm.toStringAsFixed(0)} km',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700),
                          ),
                          if (store.serviceNote.isNotEmpty)
                            Text(store.serviceNote,
                                style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Clear reminder',
                      icon: const Icon(Icons.close),
                      onPressed: () => _c.fuelLogStore.clearServiceReminder(),
                    ),
                  ],
                )
              : Row(
                  children: <Widget>[
                    Icon(Icons.build_outlined, color: scheme.outline),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Set a reminder for your next service by odometer reading.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _setServiceReminder,
                      child: const Text('Set'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _optionCard(
    String id,
    IconData icon,
    String label,
    bool selected,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: _saving ? null : () => _select(id),
      color: selected ? scheme.primary.withValues(alpha: 0.06) : null,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.14)
                  : scheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: scheme.primary, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (selected)
            Icon(Icons.check_circle, color: scheme.primary)
          else
            Icon(Icons.circle_outlined, color: scheme.outline),
        ],
      ),
    );
  }
}
