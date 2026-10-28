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
import '../../../core/widgets/private_storage_image.dart';
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
  final Set<String> _repairingPublicIds = <String>{};

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
        _repairLegacyPublicRecords(ids);
      }
    }, onError: (Object e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Cloud Digital IDs are unavailable. Check your connection and retry.';
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

  void _repairLegacyPublicRecords(List<DigitalId> ids) {
    for (final DigitalId id in ids) {
      if (!DigitalId.isValidTokenShape(id.token) ||
          !_repairingPublicIds.add(id.id)) {
        continue;
      }
      unawaited(_c.digitalIdRepository.ensurePublic(id).catchError((Object _) {
        if (mounted) {
          setState(() => _error =
              'A legacy verification record could not be updated. Retry while online.');
        }
      }).whenComplete(() => _repairingPublicIds.remove(id.id)));
    }
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
        photoPath: p?.photoPath,
        emergencyContactName: _contactNameController.text.trim(),
        emergencyContactPhone: contactPhone,
      );
      if (mounted) setState(() => _creating = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = 'Digital ID was not created. Nothing was saved; check your connection and retry.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create a verifiable Digital ID.')),
        );
      }
    }
  }

  Future<void> _setActive(DigitalId id, bool active) async {
    try {
      await _c.digitalIdRepository.setActive(id.id, active);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Update failed. Verification status was not changed.')),
        );
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
            color: scheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: active
                    ? AppTheme.success.withValues(alpha: 0.4)
                    : scheme.outlineVariant),
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'TOURISM EMERGENCY ID',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
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
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      active ? 'ACTIVE' : 'REVOKED',
                      style: TextStyle(
                          color: active ? AppTheme.success : AppTheme.danger,
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
                    backgroundColor: scheme.primary.withValues(alpha: 0.12),
                    child: (id.photoPath?.isNotEmpty ?? false) ||
                            (id.photoUrl?.isNotEmpty ?? false)
                        ? ClipOval(
                            child: PrivateStorageImage(
                              storagePath: id.photoPath,
                              legacyUrl: id.photoUrl,
                              width: 64,
                              height: 64,
                              maxBytes: 5 * 1024 * 1024,
                              placeholder:
                                  Icon(Icons.person, color: scheme.primary),
                            ),
                          )
                        : Icon(Icons.person,
                            size: 34, color: scheme.primary),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          id.ownerName,
                          style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 20,
                              fontWeight: FontWeight.w800),
                        ),
                        if (id.emergencyContactName != null &&
                            id.emergencyContactName!.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            'Contact: ${id.emergencyContactName}',
                            style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 13),
                          ),
                        ],
                        if (id.emergencyContactPhone != null &&
                            id.emergencyContactPhone!.isNotEmpty)
                          Text(
                            id.emergencyContactPhone!,
                            style: TextStyle(
                                color: scheme.onSurfaceVariant,
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
                // A token shorter than 16 chars (a legacy or hand-written doc)
                // used to throw RangeError here and red-screen the whole card.
                'Token: ${_shortToken(id.token)}',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                'Created ${Fmt.date(id.createdAt)}',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 12),
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

/// "a1b2c3d4…9f8e7d6c" for a normal 64-char token, and a safe truncation for
/// anything shorter (a legacy or partially written document used to throw
/// RangeError here and blank the whole ID card).
String _shortToken(String token) {
  const int edge = 8;
  if (token.length <= edge * 2) return token;
  return '${token.substring(0, edge)}…${token.substring(token.length - edge)}';
}
