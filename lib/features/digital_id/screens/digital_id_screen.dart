import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/digital_id.dart';
import '../../../data/models/profile.dart';

/// Digital Emergency ID: a real profile with a QR code that contains ONLY
/// the verification token (64 random hex chars) — never personal data.
class DigitalIdScreen extends StatefulWidget {
  const DigitalIdScreen({super.key});

  @override
  State<DigitalIdScreen> createState() => _DigitalIdScreenState();
}

class _DigitalIdScreenState extends State<DigitalIdScreen> {
  AppContainer get _c => AppScope.of(context);

  final List<DigitalId> _ids = <DigitalId>[];
  bool _loading = true;
  bool _creating = false;
  String? _error;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _contactNameController =
      TextEditingController();
  final TextEditingController _contactPhoneController =
      TextEditingController();
  Profile? _profile;
  StreamSubscription<List<DigitalId>>? _sub;
  StreamSubscription<Profile?>? _profileSub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    _sub = _c.digitalIdRepository
        .watchMine(uid)
        .listen((List<DigitalId> ids) {
      if (mounted) {
        setState(() {
          _ids.clear();
          _ids.addAll(ids);
          _loading = false;
        });
      }
    }, onError: (Object e) {
      // Cloud unavailable — keep the screen usable (local creation still
      // works), instead of blocking on a raw error.
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    });
    _profileSub = _c.profileRepository
        .watch(uid)
        .listen((Profile? p) {
      if (!mounted) return;
      setState(() => _profile = p);
      _prefill();
    }, onError: (Object _) {});
  }

  void _prefill() {
    final Profile? p = _profile;
    if (p == null) return;
    if (_nameController.text.isEmpty) _nameController.text = p.name;
    if (_contactNameController.text.isEmpty) {
      _contactNameController.text = p.emergencyContactName;
    }
    if (_contactPhoneController.text.isEmpty) {
      _contactPhoneController.text = p.emergencyContactPhone;
    }
  }

  Future<void> _create() async {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    final String name = _nameController.text.trim();
    final String? nameError = Validators.requiredText(name, max: 80);
    if (nameError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(nameError)));
      return;
    }
    final String contactPhone = _contactPhoneController.text.trim();
    final String? phoneError = contactPhone.isEmpty
        ? null
        : Validators.phone(contactPhone);
    if (phoneError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(phoneError)));
      return;
    }
    final Profile? p = _profile;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      await _c.digitalIdRepository.create(
        uid: uid,
        ownerName: name,
        photoUrl: p?.photoUrl,
        emergencyContactName: _contactNameController.text.trim(),
        emergencyContactPhone: contactPhone,
      );
      // The watchMine stream refreshes the list.
    } catch (e) {
      // Cloud unavailable (rules not deployed / offline) — create a local ID
      // so the QR code still works right now.
      final DigitalId local = DigitalId(
        id: 'local-${DateTime.now().millisecondsSinceEpoch}',
        uid: uid,
        ownerName: name,
        token: DigitalId.generateToken(),
        status: 'active',
        createdAt: DateTime.now(),
        photoUrl: p?.photoUrl,
        emergencyContactName: _contactNameController.text.trim(),
        emergencyContactPhone: contactPhone,
      );
      if (mounted) {
        setState(() {
          _ids.insert(0, local);
          _creating = false;
          _error =
              'Created on this device — cloud sync is unavailable right now.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Digital ID created (saved on this device).')),
        );
      }
    }
  }

  Future<void> _setActive(DigitalId id, bool active) async {
    if (id.id.startsWith('local-')) {
      // On-device ID: just flip the in-memory status.
      setState(() {
        final int i = _ids.indexWhere((DigitalId d) => d.id == id.id);
        if (i >= 0) {
          _ids[i] = DigitalId(
            id: id.id,
            uid: id.uid,
            ownerName: id.ownerName,
            token: id.token,
            status: active ? 'active' : 'revoked',
            createdAt: id.createdAt,
            photoUrl: id.photoUrl,
            emergencyContactName: id.emergencyContactName,
            emergencyContactPhone: id.emergencyContactPhone,
          );
        }
      });
      return;
    }
    try {
      await _c.digitalIdRepository.setActive(id.id, active);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update failed: $e')));
      }
    }
  }

  Future<void> _copyToken(DigitalId id) async {
    await Clipboard.setData(ClipboardData(text: id.token));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verification token copied.')),
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _profileSub?.cancel();
    _nameController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Emergency ID')),
        body: const LoadingView(message: 'Loading your digital ID…'),
      );
    }
    final DigitalId? current = _ids.isEmpty ? null : _ids.first;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Digital Emergency ID'),
        actions: <Widget>[
          TextButton.icon(
            icon: const Icon(Icons.qr_code_scanner, size: 20),
            label: const Text('Verify'),
            onPressed: () => context.push('/digital-id/verify'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
          if (current != null)
            _idCard(current, scheme)
          else
            _createCard(scheme),
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Icon(Icons.info_outline, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The QR code contains only a random verification token — '
                    'no name, phone or other personal data. First responders '
                    'scan it (or type the token) and the app verifies it '
                    'against Tourism\'s secure records.',
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

  Widget _idCard(DigitalId id, ColorScheme scheme) {
    final bool active = id.isActive;
    return Column(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                active ? const Color(0xFF0B3954) : const Color(0xFF37474F),
                active ? const Color(0xFF0E7C7B) : const Color(0xFF546E7A),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'YATRAWISE EMERGENCY ID',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (active ? AppTheme.success : AppTheme.danger)
                          .withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      active ? 'ACTIVE' : 'REVOKED',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: Colors.white24,
                    child: id.photoUrl != null && id.photoUrl!.isNotEmpty
                        ? ClipOval(
                            child: Image.network(
                              id.photoUrl!,
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                              errorBuilder: (BuildContext context,
                                  Object e, StackTrace? s) =>
                                  const Icon(Icons.person),
                            ),
                          )
                        : const Icon(Icons.person,
                            size: 34, color: Colors.white70),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          id.ownerName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800),
                        ),
                        if (id.emergencyContactName != null &&
                            id.emergencyContactName!.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            'Contact: ${id.emergencyContactName}',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13),
                          ),
                        ],
                        if (id.emergencyContactPhone != null &&
                            id.emergencyContactPhone!.isNotEmpty)
                          Text(
                            id.emergencyContactPhone!,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: id.token,
                  version: QrVersions.auto,
                  size: 180,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Token: ${id.token.substring(0, 8)}…${id.token.substring(id.token.length - 8)}',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                'Created ${Fmt.date(id.createdAt)}',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: PrimaryButton(
                label: 'Copy token',
                icon: Icons.copy,
                outlined: true,
                onPressed: () => _copyToken(id),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PrimaryButton(
                label: active ? 'Revoke ID' : 'Reactivate ID',
                icon: active ? Icons.block : Icons.restart_alt,
                danger: active,
                onPressed: () => _setActive(id, !active),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _createCard(ColorScheme scheme) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Create your digital emergency ID',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Shown to first responders via QR scan. Only a verification '
            'token is encoded — your details stay in your secure profile.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Your name',
              prefixIcon: Icon(Icons.person),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contactNameController,
            decoration: const InputDecoration(
              labelText: 'Emergency contact name (optional)',
              prefixIcon: Icon(Icons.contacts),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contactPhoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Emergency contact phone (optional)',
              prefixIcon: Icon(Icons.phone),
            ),
          ),
          const SizedBox(height: 18),
          PrimaryButton(
            label: 'Create digital ID',
            icon: Icons.badge,
            loading: _creating,
            onPressed: _creating ? null : _create,
          ),
        ],
      ),
    );
  }
}
