import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/profile.dart';

/// Profile: identity, photo, language, emergency contact, travel
/// preferences — all persisted in Firestore — plus shortcuts to the
/// user's data and sign-out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  AppContainer get _c => AppScope.of(context);

  Profile? _profile;
  bool _loading = true;
  StreamSubscription<Profile?>? _sub;
  bool _saving = false;
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    _sub = _c.profileRepository
        .watch(uid)
        .listen((Profile? p) {
      if (mounted) {
        setState(() {
          _profile = p;
          _loading = false;
        });
      }
    }, onError: (Object _) {});
  }

  Future<void> _signOut() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
            'You can sign back in with Google at any time. Your data stays '
            'securely saved in your account.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    await _c.authRepository.signOut();
    if (mounted) context.go('/login');
  }

  void _editProfile() {
    final Profile? p = _profile;
    if (p == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => _EditProfileSheet(
        profile: p,
        saving: _saving,
        onSave: (Profile next) async {
          await _c.profileRepository.update(
            next.uid,
            name: next.name,
            photoUrl: next.photoUrl,
            language: next.language,
            emergencyContactName: next.emergencyContactName,
            emergencyContactPhone: next.emergencyContactPhone,
            interests: next.interests,
            budget: next.budget,
            travelStyle: next.travelStyle,
          );
          if (ctx.mounted) Navigator.of(ctx).pop();
        },
      ),
    );
  }

  Future<void> _uploadAvatar() async {
    final Profile? p = _profile;
    final String? uid = _c.authRepository.currentUser?.uid;
    if (p == null || uid == null) return;
    setState(() => _uploadingPhoto = true);
    try {
      final XFile? file = await _c.storageService.pickAvatar();
      if (file == null) {
        if (mounted) setState(() => _uploadingPhoto = false);
        return;
      }
      final String url = await _c.storageService.uploadAvatar(file, uid);
      await _c.profileRepository.update(
        uid,
        name: p.name,
        photoUrl: url,
        language: p.language,
        emergencyContactName: p.emergencyContactName,
        emergencyContactPhone: p.emergencyContactPhone,
        interests: p.interests,
        budget: p.budget,
        travelStyle: p.travelStyle,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Photo upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Widget _linkTile(
      IconData icon, String label, String subtitle, String route) {
    return AppCard(
      onTap: () => context.push(route),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final User? user = _c.authRepository.currentUser;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const LoadingView(message: 'Loading profile…'),
      );
    }
    final Profile? p = _profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // Identity header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Color(0xFF0B3954), Color(0xFF0E7C7B)],
              ),
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            ),
            child: Column(
              children: <Widget>[
                Stack(
                  children: <Widget>[
                    CircleAvatar(
                      radius: 40,
                      backgroundColor: Colors.white24,
                      child: (p?.photoUrl != null &&
                              p!.photoUrl!.isNotEmpty)
                          ? ClipOval(
                              child: Image.network(
                                p!.photoUrl!,
                                width: 80,
                                height: 80,
                                fit: BoxFit.cover,
                                errorBuilder: (BuildContext context,
                                        Object e, StackTrace? s) =>
                                    const Icon(Icons.person,
                                        size: 40, color: Colors.white70),
                              ),
                            )
                          : Text(
                              (p?.name?.isNotEmpty == true)
                                  ? p!.name[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white),
                            ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Material(
                        color: Colors.white,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _uploadingPhoto ? null : _uploadAvatar,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: _uploadingPhoto
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.camera_alt,
                                    size: 14, color: Color(0xFF0B3954)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  (p?.name?.isNotEmpty ?? false)
                      ? p!.name
                      : (user?.displayName ?? 'Traveler'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800),
                ),
                if (user?.email != null)
                  Text(
                    user!.email!,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8), fontSize: 13),
                  ),
                if (_c.authState.isAdmin) ...<Widget>[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.admin_panel_settings,
                            size: 12, color: Colors.white),
                        SizedBox(width: 4),
                        Text(
                          'Administrator',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Saved details
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Your details',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('Edit'),
                      onPressed: _profile == null ? null : _editProfile,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (p == null)
                  const Text(
                    'No profile yet — sign in completed setup.',
                    style: TextStyle(),
                  )
                else ...<Widget>[
                  _infoRow(Icons.translate,
                      'Language', kLanguageNames[p.language] ?? p.language),
                  _infoRow(Icons.contacts, 'Emergency contact',
                      p.emergencyContactName.isNotEmpty
                          ? '${p.emergencyContactName} (${p.emergencyContactPhone})'
                          : 'Not set'),
                  _infoRow(Icons.account_balance_wallet, 'Budget',
                      _budgetLabel(p.budget)),
                  _infoRow(Icons.style, 'Travel style', _styleLabel(p.travelStyle)),
                  const SizedBox(height: 8),
                  Text(
                    'Interests',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final String i in p.interests)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            i,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your data',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          _linkTile(Icons.badge, 'Digital Emergency ID',
              'QR code for first responders', '/digital-id'),
          const SizedBox(height: 8),
          _linkTile(Icons.travel_explore, 'Itineraries',
              'Generated trip plans', '/itineraries'),
          const SizedBox(height: 8),
          _linkTile(Icons.eco, 'Eco Score', 'Sustainable travel tracking',
              '/eco'),
          const SizedBox(height: 8),
          _linkTile(Icons.report_problem, 'Incident history',
              'Your reports and their status', '/incidents'),
          const SizedBox(height: 8),
          _linkTile(Icons.notifications, 'Notifications',
              'Alerts and history', '/notifications'),
          const SizedBox(height: 8),
          if (_c.authState.isAdmin)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _linkTile(Icons.admin_panel_settings, 'Admin area',
                  'Manage zones, incidents, emergencies', '/admin'),
            ),
          const SizedBox(height: 16),
          PrimaryButton(
            label: 'Sign out',
            icon: Icons.logout,
            danger: true,
            onPressed: _signOut,
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'YatraWise 1.0.0 · data encrypted in transit and at rest',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  String _budgetLabel(String b) => switch (b) {
        'budget' => 'Budget',
        'luxury' => 'Luxury',
        _ => 'Mid-range',
      };

  String _styleLabel(String s) => switch (s) {
        'relaxed' => 'Relaxed',
        'packed' => 'Packed',
        _ => 'Balanced',
      };
}

class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({
    required this.profile,
    required this.saving,
    required this.onSave,
  });

  final Profile profile;
  final bool saving;
  final Future<void> Function(Profile next) onSave;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late final TextEditingController _name;
  late final TextEditingController _contactName;
  late final TextEditingController _contactPhone;
  late String _language;
  late String _budget;
  late String _style;
  late List<String> _interests;

  @override
  void initState() {
    super.initState();
    final Profile p = widget.profile;
    _name = TextEditingController(text: p.name);
    _contactName = TextEditingController(text: p.emergencyContactName);
    _contactPhone = TextEditingController(text: p.emergencyContactPhone);
    _language = p.language;
    _budget = p.budget;
    _style = p.travelStyle;
    _interests = List<String>.of(p.interests);
  }

  @override
  void dispose() {
    _name.dispose();
    _contactName.dispose();
    _contactPhone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    final String? nameError = Validators.requiredText(name, max: 80);
    if (nameError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(nameError)));
      return;
    }
    final String phone = _contactPhone.text.trim();
    final String? phoneError =
        phone.isEmpty ? null : Validators.phone(phone);
    if (phoneError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(phoneError)));
      return;
    }
    final Profile p = widget.profile;
    final Profile next = Profile(
      uid: p.uid,
      name: name,
      photoUrl: p.photoUrl,
      language: _language,
      emergencyContactName: _contactName.text.trim(),
      emergencyContactPhone: phone,
      interests: _interests,
      budget: _budget,
      travelStyle: _style,
      updatedAt: p.updatedAt,
    );
    setState(() {});
    await widget.onSave(next);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 24),
      child: StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheet) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Edit profile',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                      labelText: 'Name', prefixIcon: Icon(Icons.person)),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _language,
                  decoration:
                      const InputDecoration(labelText: 'Language'),
                  items: <DropdownMenuItem<String>>[
                    for (final String code in kSupportedLanguages)
                      DropdownMenuItem<String>(
                          value: code,
                          child: Text(kLanguageNames[code] ?? code)),
                  ],
                  onChanged: (String? v) {
                    if (v != null) setSheet(() => _language = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contactName,
                  decoration: const InputDecoration(
                      labelText: 'Emergency contact name',
                      prefixIcon: Icon(Icons.contacts)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contactPhone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                      labelText: 'Emergency contact phone',
                      prefixIcon: Icon(Icons.phone)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _budget,
                        decoration:
                            const InputDecoration(labelText: 'Budget'),
                        items: <DropdownMenuItem<String>>[
                          for (final String b in kBudgetLevels)
                            DropdownMenuItem<String>(
                                value: b,
                                child: Text(
                                    _budgetLabel(b).toUpperCase())),
                        ],
                        onChanged: (String? v) {
                          if (v != null) setSheet(() => _budget = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _style,
                        decoration:
                            const InputDecoration(labelText: 'Travel style'),
                        items: <DropdownMenuItem<String>>[
                          for (final String s in kTravelStyles)
                            DropdownMenuItem<String>(
                                value: s,
                                child: Text(_styleLabel(s).toUpperCase())),
                        ],
                        onChanged: (String? v) {
                          if (v != null) setSheet(() => _style = v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Interests',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final String option in kInterestOptions)
                      ChoiceChip(
                        label: Text(option),
                        selected: _interests.contains(option),
                        onSelected: (bool sel) {
                          setSheet(() {
                            if (sel) {
                              _interests.add(option);
                            } else {
                              _interests.remove(option);
                            }
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                PrimaryButton(
                  label: 'Save changes',
                  icon: Icons.save,
                  loading: widget.saving,
                  onPressed: widget.saving ? null : _save,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _budgetLabel(String b) => switch (b) {
        'budget' => 'Budget',
        'luxury' => 'Luxury',
        _ => 'Mid-range',
      };

  String _styleLabel(String s) => switch (s) {
        'relaxed' => 'Relaxed',
        'packed' => 'Packed',
        _ => 'Balanced',
      };
}
