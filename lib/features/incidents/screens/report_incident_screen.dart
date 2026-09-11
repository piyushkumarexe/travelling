import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/badges.dart';
import '../../../data/models/incident.dart';

/// AI incident reporting: description + photo/video + current location.
/// Media goes to Firebase Storage (validated), NVIDIA AI triages the report
/// (category/severity/summary/action) and the result is stored in Firestore.
class ReportIncidentScreen extends StatefulWidget {
  const ReportIncidentScreen({super.key});

  @override
  State<ReportIncidentScreen> createState() => _ReportIncidentScreenState();
}

enum _Stage { form, submitting, success }

class _ReportIncidentScreenState extends State<ReportIncidentScreen> {
  AppContainer get _c => AppScope.of(context);

  _Stage _stage = _Stage.form;
  String _submitPhase = '';
  String? _error;

  final TextEditingController _descController = TextEditingController();
  XFile? _photo;
  XFile? _video;
  bool _pickingPhoto = false;
  bool _pickingVideo = false;

  Position? _position;
  bool _locationDone = false;

  Map<String, String>? _analysis;
  Incident? _created;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  Future<void> _loadLocation() async {
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (mounted) {
        setState(() {
          _position = pos;
          _locationDone = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _locationDone = true);
    }
  }

  Future<void> _pickPhoto() async {
    setState(() => _pickingPhoto = true);
    try {
      final XFile? file = await _c.storageService.pickImage();
      if (file != null && mounted) setState(() => _photo = file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not pick image: $e')));
      }
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  Future<void> _pickVideo() async {
    setState(() => _pickingVideo = true);
    try {
      final XFile? file = await _c.storageService.pickVideo();
      if (file != null && mounted) setState(() => _video = file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not pick video: $e')));
      }
    } finally {
      if (mounted) setState(() => _pickingVideo = false);
    }
  }

  Future<void> _submit() async {
    final String desc = _descController.text.trim();
    final String? descError = Validators.description(desc);
    if (descError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(descError)));
      return;
    }
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You must be signed in to report.')),
      );
      return;
    }
    final Position? pos = _position;
    if (pos == null) {
      if (mounted) {
        setState(() {
          _error = 'Location is required for an incident report. '
              'Enable location services and retry.';
          _stage = _Stage.form;
        });
      }
      return;
    }

    setState(() {
      _stage = _Stage.submitting;
      _error = null;
      _submitPhase = 'Starting…';
    });
    try {
      String? photoUrl;
      if (_photo != null) {
        if (mounted) setState(() => _submitPhase = 'Uploading photo…');
        photoUrl = await _c.storageService.uploadIncidentImage(_photo!, uid);
      }
      String? videoUrl;
      if (_video != null) {
        if (mounted) setState(() => _submitPhase = 'Uploading video…');
        videoUrl = await _c.storageService.uploadIncidentVideo(_video!, uid);
      }

      if (mounted) setState(() => _submitPhase = 'Analyzing with AI…');
      final String? label = await _c.placesRepository
          .reverseGeocode(LatLng(pos.latitude, pos.longitude))
          .catchError((Object _) => null as String?);
      final Map<String, String> analysis = await _c.aiRepository
          .analyzeIncident(
        description: desc,
        locationLabel: label,
        hasPhoto: photoUrl != null,
        hasVideo: videoUrl != null,
      );

      if (mounted) setState(() => _submitPhase = 'Saving report…');
      final String reporter = (await _c.profileRepository.get(uid))?.name ??
          _c.authRepository.currentUser?.displayName ??
          'Unknown';
      final Incident incident = Incident(
        id: '',
        uid: uid,
        reporterName: reporter,
        description: desc,
        category: analysis['category'] ?? 'other',
        severity: analysis['severity'] ?? 'medium',
        status: 'reported',
        lat: pos.latitude,
        lng: pos.longitude,
        summary: analysis['summary'],
        recommendedAction: analysis['recommendedAction'],
        photoUrl: photoUrl,
        videoUrl: videoUrl,
        createdAt: DateTime.now(),
      );
      final String id = await _c.incidentsRepository.create(incident);
      final Incident created = Incident(
        id: id,
        uid: uid,
        reporterName: incident.reporterName,
        description: incident.description,
        category: incident.category,
        severity: incident.severity,
        status: incident.status,
        lat: incident.lat,
        lng: incident.lng,
        summary: incident.summary,
        recommendedAction: incident.recommendedAction,
        photoUrl: incident.photoUrl,
        videoUrl: incident.videoUrl,
        createdAt: incident.createdAt,
      );

      unawaited(_c.notificationsRepository
          .add(
            uid: uid,
            title: 'Incident reported',
            body: 'Your ${created.categoryLabel.toLowerCase()} report was '
                'submitted and saved securely.',
            type: 'incident',
            payload: <String, dynamic>{'incidentId': id},
          )
          .catchError((Object _) => ''));

      if (!mounted) return;
      setState(() {
        _stage = _Stage.success;
        _created = created;
        _analysis = analysis;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.form;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    switch (_stage) {
      case _Stage.submitting:
        return Scaffold(
          appBar: AppBar(title: const Text('Report incident')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    _submitPhase.isEmpty ? 'Working…' : _submitPhase,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This can take a moment while media is uploaded and '
                    'the report is analyzed.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      case _Stage.success:
        return _successView(scheme);
      case _Stage.form:
        return _formView(scheme);
    }
  }

  Widget _formView(ColorScheme scheme) {
    return Scaffold(
      appBar: AppBar(title: const Text('Report an incident')),
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
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'What happened?',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descController,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText:
                        'Describe the incident, what you saw, and where. '
                        'The more detail, the better the AI triage.',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Photos & video (optional)',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: _pickingPhoto
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.photo_camera, size: 18),
                        label: Text(_photo == null ? 'Add photo' : 'Photo added ✓'),
                        onPressed: _photo == null ? _pickPhoto : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: _pickingVideo
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.videocam, size: 18),
                        label: Text(_video == null ? 'Add video' : 'Video added ✓'),
                        onPressed: _video == null ? _pickVideo : null,
                      ),
                    ),
                  ],
                ),
                if (_photo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(_photo!.path),
                        height: 140,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                if (_video != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.videocam),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _video!.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _video = null),
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  'Images up to 10 MB (JPG/PNG/WEBP) · videos up to 50 MB '
                  '(MP4/MOV/WEBM). Stored securely in Firebase Storage.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: Row(
              children: <Widget>[
                Icon(Icons.my_location,
                    color: _position != null
                        ? AppTheme.success
                        : scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Current location',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        _locationDone
                            ? (_position == null
                                ? 'Location unavailable — enable GPS and retry'
                                : '${_position!.latitude.toStringAsFixed(5)}, '
                                    '${_position!.longitude.toStringAsFixed(5)} '
                                    '(±${_position!.accuracy.round()} m)')
                            : 'Getting location…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (_locationDone && _position == null)
                  TextButton(
                    onPressed: _loadLocation,
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          PrimaryButton(
            label: 'Submit report',
            icon: Icons.send,
            onPressed: _submit,
          ),
          const SizedBox(height: 10),
          Text(
            'Submitting uploads your media, captures your location, runs AI '
            'triage (category, severity, recommended action) and stores '
            'everything securely. Only you and authorized administrators '
            'can view the report.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _successView(ColorScheme scheme) {
    final Incident? created = _created;
    final Map<String, String>? a = _analysis;
    return Scaffold(
      appBar: AppBar(title: const Text('Report submitted')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle,
                  size: 44, color: AppTheme.success),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your incident report was submitted',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'It is stored securely and visible to you and authorized '
            'administrators for follow-up.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          if (created != null && a != null) ...<Widget>[
            const SizedBox(height: 20),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'AI analysis',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      StatusBadge(
                        label: created.severityLabel,
                        color: RiskBadge.colorFor(context, created.severity),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _kv('Category', created.categoryLabel),
                  if ((a['summary'] ?? '').isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    _kv('Summary', a['summary']!),
                  ],
                  if ((a['recommendedAction'] ?? '').isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    _kv('Recommended action', a['recommendedAction']!),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              Expanded(
                child: PrimaryButton(
                  label: 'Incident history',
                  icon: Icons.history,
                  outlined: true,
                  onPressed: () => context.go('/incidents'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PrimaryButton(
                  label: 'Done',
                  icon: Icons.check,
                  onPressed: () => context.go('/home'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          k,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 2),
        Text(v, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}
