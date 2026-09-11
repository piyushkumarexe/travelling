import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/safety_zone.dart';

/// Create or edit a safety zone (admin-only, enforced server-side).
class ZoneEditorScreen extends StatefulWidget {
  const ZoneEditorScreen({super.key, this.zoneId});

  /// Null creates a new zone; otherwise edits the given zone.
  final String? zoneId;

  @override
  State<ZoneEditorScreen> createState() => _ZoneEditorScreenState();
}

class _ZoneEditorScreenState extends State<ZoneEditorScreen> {
  AppContainer get _c => AppScope.of(context);

  bool _loading = true;
  bool _saving = false;
  SafetyZone? _zone;
  String? _error;

  final TextEditingController _name = TextEditingController();
  final TextEditingController _lat = TextEditingController();
  final TextEditingController _lng = TextEditingController();
  final TextEditingController _radius = TextEditingController();
  final TextEditingController _description = TextEditingController();
  String _risk = 'medium';
  bool _active = true;
  String? _adminName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid != null) {
        _adminName = (await _c.profileRepository.get(uid))?.name ??
            _c.authRepository.currentUser?.displayName;
      }
      final String? id = widget.zoneId;
      if (id == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final List<SafetyZone> all = await _c.zonesRepository.getAll();
      final SafetyZone? z =
          all.where((SafetyZone s) => s.id == id).cast<SafetyZone?>().firstWhere(
                (SafetyZone? s) => s != null,
                orElse: () => null,
              );
      if (!mounted) return;
      if (z == null) {
        setState(() {
          _error = 'Zone not found.';
          _loading = false;
        });
        return;
      }
      _name.text = z.name;
      _lat.text = z.lat.toStringAsFixed(6);
      _lng.text = z.lng.toStringAsFixed(6);
      _radius.text = z.radiusMeters.toStringAsFixed(0);
      _description.text = z.description;
      _risk = z.riskLevel;
      _active = z.active;
      _zone = z;
      setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    final String? nameError = Validators.requiredText(name, max: 80);
    if (nameError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(nameError)));
      return;
    }
    final double? lat = double.tryParse(_lat.text.trim().replaceAll(',', '.'));
    if (!Validators.isLat(lat)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a latitude between -90 and 90.')));
      return;
    }
    final double? lng = double.tryParse(_lng.text.trim().replaceAll(',', '.'));
    if (!Validators.isLng(lng)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Enter a longitude between -180 and 180.')));
      return;
    }
    final double? radius = double.tryParse(_radius.text.trim());
    if (radius == null || radius < 100 || radius > 10000) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Radius must be between 100 and 10,000 meters.')));
      return;
    }

    final String adminName = _adminName ?? 'Administrator';
    setState(() => _saving = true);
    try {
      final SafetyZone? existing = _zone;
      if (existing == null) {
        await _c.zonesRepository.create(
          <String, dynamic>{
            'name': name,
            'lat': lat,
            'lng': lng,
            'radiusMeters': radius,
            'riskLevel': _risk,
            'description': _description.text.trim(),
            'active': _active,
          },
          createdByName: adminName,
        );
      } else {
        await _c.zonesRepository.update(
          existing.id,
          <String, dynamic>{
            'name': name,
            'lat': lat,
            'lng': lng,
            'radiusMeters': radius,
            'riskLevel': _risk,
            'description': _description.text.trim(),
            'active': _active,
          },
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Zone saved.')),
        );
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Future<void> _delete() async {
    final SafetyZone? z = _zone;
    if (z == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete zone?'),
        content: Text(
            '“${z.name}” will be removed. Travelers will no longer receive '
            'warnings for this area.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _c.zonesRepository.remove(z.id);
      if (mounted) {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lng.dispose();
    _radius.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_zone == null ? 'New safety zone' : 'Edit zone'),
      ),
      body: _loading
          ? const LoadingView(message: 'Loading zone…')
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          TextField(
                            controller: _name,
                            decoration: const InputDecoration(
                                labelText: 'Zone name',
                                prefixIcon: Icon(Icons.place)),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: TextField(
                                  controller: _lat,
                                  keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true, signed: true),
                                  decoration:
                                      const InputDecoration(labelText: 'Latitude'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _lng,
                                  keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true, signed: true),
                                  decoration:
                                      const InputDecoration(labelText: 'Longitude'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _radius,
                            keyboardType:
                                const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Radius (meters)',
                                prefixIcon: Icon(Icons.straighten)),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: _risk,
                            decoration: const InputDecoration(
                                labelText: 'Risk level'),
                            items: const <DropdownMenuItem<String>>[
                              DropdownMenuItem<String>(
                                  value: 'low', child: Text('Low')),
                              DropdownMenuItem<String>(
                                  value: 'medium', child: Text('Medium')),
                              DropdownMenuItem<String>(
                                  value: 'high', child: Text('High')),
                              DropdownMenuItem<String>(
                                  value: 'critical', child: Text('Critical')),
                            ],
                            onChanged: (String? v) {
                              if (v != null) setState(() => _risk = v);
                            },
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _description,
                            maxLines: 3,
                            decoration: const InputDecoration(
                                labelText: 'Safety information (optional)',
                                hintText:
                                    'Shown to travelers when they enter or view this zone.'),
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Zone active'),
                            subtitle: const Text(
                                'Active zones trigger entry warnings for '
                                'high-risk levels'),
                            value: _active,
                            onChanged: (bool v) => setState(() => _active = v),
                          ),
                        ],
                      ),
                    ),
                    if (_zone != null) ...<Widget>[
                      const SizedBox(height: 12),
                      PrimaryButton(
                        label: 'Delete zone',
                        icon: Icons.delete_outline,
                        danger: true,
                        outlined: true,
                        onPressed: _saving ? null : _delete,
                      ),
                      const SizedBox(height: 12),
                    ],
                    PrimaryButton(
                      label: _zone == null ? 'Create zone' : 'Save changes',
                      icon: Icons.save,
                      loading: _saving,
                      onPressed: _saving ? null : _save,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Changes apply to every traveler immediately. Zones are '
                      'enforce-able only by administrators (Firebase security '
                      'rules).',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
    );
  }
}
