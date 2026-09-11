import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/state/app_container.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/profile.dart';

/// Vehicle — choose how you usually travel (Bike / Car / Auto).
///
/// The choice is saved to your profile. Ride-hailing price data (Rapido,
/// Uber, Ola) will plug into this tab in a future update.
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
    if (uid == null) {
      _loading = false;
      return;
    }
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
  }

  @override
  void dispose() {
    _sub?.cancel();
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
