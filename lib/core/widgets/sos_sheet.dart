import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/format.dart';
import '../../core/widgets/app_button.dart';
import '../../data/models/emergency_event.dart';
import '../../data/models/places.dart';
import '../state/app_container.dart';
import '../theme/app_theme.dart';

/// Shows the global SOS bottom sheet from anywhere in the app.
void showSOSSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) => const _SosSheetView(),
  );
}

class _SosSheetView extends StatefulWidget {
  const _SosSheetView();

  @override
  State<_SosSheetView> createState() => _SosSheetViewState();
}

enum _SosStage { confirm, creating, active }

class _SosSheetViewState extends State<_SosSheetView> {
  _SosStage _stage = _SosStage.confirm;
  EmergencyEvent? _event;
  Position? _position;
  List<Place> _services = <Place>[];
  bool _loadingServices = false;
  String? _error;

  AppContainer get _c => AppScope.of(context);

  Future<void> _activate() async {
    setState(() {
      _stage = _SosStage.creating;
      _error = null;
    });
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted) return;
      if (pos == null) {
        setState(() {
          _stage = _SosStage.confirm;
          _error = 'Could not get your location. Enable location services '
              '(GPS + location permission) and try again — SOS needs GPS.';
        });
        return;
      }
      final user = _c.authRepository.currentUser;
      if (user == null) {
        setState(() {
          _stage = _SosStage.confirm;
          _error = 'You must be signed in to activate SOS.';
        });
        return;
      }
      final String uid = user.uid;
      final String? profileName =
          (await _c.profileRepository.get(uid))?.name;
      final String name = (profileName == null || profileName.isEmpty)
          ? (user.displayName ?? 'Unknown')
          : profileName;

      final String id = await _c.emergencyRepository.create(
        uid: uid,
        name: name,
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyMeters: pos.accuracy,
      );
      if (!mounted) return;

      final EmergencyEvent event = EmergencyEvent(
        id: id,
        uid: uid,
        name: name,
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyMeters: pos.accuracy,
        status: 'active',
        createdAt: DateTime.now(),
      );
      setState(() {
        _position = pos;
        _event = event;
        _stage = _SosStage.active;
      });

      // Persist in-app notification record + real Android notification.
      unawaitedAdd(uid, id, name);
      _c.notificationService.show(
        id: DateTime.now().millisecondsSinceEpoch % 1000000,
        title: '🆘 SOS activated',
        body: 'Your location was recorded at '
            '${pos.latitude.toStringAsFixed(5)}, '
            '${pos.longitude.toStringAsFixed(5)}. Use the buttons below to '
            'call nearby emergency services.',
        channel: 'emergency',
        important: true,
        payload: 'sos:$id',
      );
      unawaited(_loadServices());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _SosStage.confirm;
        _error = 'Could not create the emergency event: $e';
      });
    }
  }

  void unawaitedAdd(String uid, String id, String name) {
    // ignore: unawaited_futures
    _c.notificationsRepository
        .add(
          uid: uid,
          title: '🆘 SOS activated',
          body: 'Emergency event created with your current location.',
          type: 'emergency',
          payload: <String, dynamic>{'eventId': id},
        )
        .catchError((Object _) {});
  }

  Future<void> _loadServices() async {
    final Position? pos = _position;
    if (pos == null) return;
    setState(() => _loadingServices = true);
    try {
      final List<Place> places =
          await _c.placesRepository.emergencyNearby(
        LatLng(pos.latitude, pos.longitude),
      );
      if (!mounted) return;
      setState(() {
        _services = places;
        _loadingServices = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingServices = false;
        _error = 'Emergency event created, but nearby services could not be '
            'loaded: $e';
      });
    }
  }

  Future<void> _cancel() async {
    final EmergencyEvent? event = _event;
    if (event == null) return;
    try {
      await _c.emergencyRepository.updateStatus(event.id, 'cancelled');
    } catch (_) {
      // Even if the update fails we still close the sheet; the event
      // remains and the user can retry from the Safety screen.
    }
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SOS cancelled. The event was marked as cancelled.')),
      );
    }
  }

  Future<void> _copyLocation() async {
    final Position? pos = _position;
    if (pos == null) return;
    await Clipboard.setData(
      ClipboardData(
        text:
            '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}',
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Coordinates copied to clipboard.')),
      );
    }
  }

  Future<void> _openMaps(String? phone, double? lat, double? lng, String label) async {
    final Uri uri;
    if (lat != null && lng != null) {
      uri = Uri.parse(
          'geo:0,0?dlat=$lat&dlng=$lng&daddr=${Uri.encodeComponent(label)}');
    } else if (phone != null) {
      uri = Uri.parse('tel:$phone');
    } else {
      uri = Uri.parse('https://www.google.com/maps');
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (phone != null) {
      final Uri tel = Uri.parse('tel:$phone');
      if (await canLaunchUrl(tel)) {
        await launchUrl(tel, mode: LaunchMode.externalApplication);
      }
    }
  }

  Future<void> _call(String phone) async {
    final String clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final Uri uri = Uri.parse('tel:$clean');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This device cannot place calls.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController scrollController) {
        return SingleChildScrollView(
          controller: scrollController,
          padding: EdgeInsets.fromLTRB(20, 0, 20, mq.viewPadding.bottom + 24),
          child: _buildBody(scheme),
        );
      },
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    switch (_stage) {
      case _SosStage.confirm:
        return _buildConfirm(scheme);
      case _SosStage.creating:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Column(
            children: <Widget>[
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Capturing your location and creating the emergency event…',
                  textAlign: TextAlign.center),
            ],
          ),
        );
      case _SosStage.active:
        return _buildActive(scheme);
    }
  }

  Widget _buildConfirm(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 8),
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: AppTheme.danger.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.sos, size: 44, color: AppTheme.danger),
        ),
        const SizedBox(height: 16),
        Text(
          'Activate SOS?',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 12),
        Text(
          'YatraWise will:\n'
          '• Capture your current GPS location\n'
          '• Create an emergency event (visible to you and authorized '
          'administrators)\n'
          '• Show an on-device alert and nearby emergency services\n'
          '• Let you call police / hospital / fire directly\n\n'
          'YatraWise does not automatically contact authorities. If you are in '
          'immediate danger, call your local emergency number first.',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _error!,
              style: TextStyle(color: scheme.onErrorContainer),
              textAlign: TextAlign.center,
            ),
          ),
        ],
        const SizedBox(height: 20),
        PrimaryButton(
          label: 'Activate SOS',
          icon: Icons.sos,
          danger: true,
          onPressed: _activate,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildActive(ColorScheme scheme) {
    final EmergencyEvent? event = _event;
    final Position? pos = _position;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.danger.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.danger.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.danger,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.sos, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'SOS ACTIVE',
                      style: TextStyle(
                        color: AppTheme.danger,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                    if (event != null)
                      Text(
                        'Since ${Fmt.time(event.createdAt)} · '
                        'Event ${event.id.substring(0, 8)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (pos != null)
          Row(
            children: <Widget>[
              const Icon(Icons.my_location, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${pos.latitude.toStringAsFixed(5)}, '
                  '${pos.longitude.toStringAsFixed(5)} '
                  '(±${pos.accuracy.round()} m)',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: PrimaryButton(
                label: 'Copy location',
                icon: Icons.copy,
                outlined: true,
                onPressed: _copyLocation,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PrimaryButton(
                label: 'Open in Maps',
                icon: Icons.map,
                outlined: true,
                onPressed: () => _openMaps(null, pos?.latitude, pos?.longitude, 'My location (SOS)'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'Cancel SOS',
          icon: Icons.close,
          danger: true,
          onPressed: _cancel,
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(_error!,
              style: TextStyle(color: scheme.error),
              textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        Text(
          'Nearby emergency services',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        if (_loadingServices)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_services.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No nearby emergency services were found. '
              'Call your local emergency number directly.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          )
        else
          ..._services.map(
            (Place p) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _serviceRow(p),
            ),
          ),
      ],
    );
  }

  Widget _serviceRow(Place p) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                p.types.contains('police_station')
                    ? Icons.local_police
                    : p.types.contains('fire_station')
                        ? Icons.local_fire_department
                        : Icons.local_hospital,
                color: AppTheme.danger,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  Text(
                    [
                      if (p.address != null) p.address!,
                      if (p.phone != null && p.phone!.isNotEmpty) '☎ ${p.phone}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (p.phone != null && p.phone!.isNotEmpty)
              IconButton(
                tooltip: 'Call',
                icon: const Icon(Icons.call, color: AppTheme.danger),
                onPressed: () => _call(p.phone!),
              ),
            IconButton(
              tooltip: 'Directions',
              icon: const Icon(Icons.directions, color: AppTheme.danger),
              onPressed: () =>
                  _openMaps(p.phone, p.lat, p.lng, p.name),
            ),
          ],
        ),
      ),
    );
  }
}

