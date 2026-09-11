import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/geo.dart';
import '../../../core/utils/price_guard.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../data/models/places.dart';

enum _Mode { check, estimate }

/// Tourism "Payment Guardian" — two honest, transparent tools:
///   1. Check a charge: compare an amount against typical local ranges.
///   2. Estimate a trip: set your location + destination to get the expected
///      local auto/taxi fare for that distance.
///
/// Every figure is a clearly-labelled *estimate*, never an accusation.
/// Ride-hailing (Rapido/Uber/Ola) prices are added separately later.
class PaymentGuardianScreen extends StatefulWidget {
  const PaymentGuardianScreen({super.key});

  @override
  State<PaymentGuardianScreen> createState() => _PaymentGuardianScreenState();
}

class _PaymentGuardianScreenState extends State<PaymentGuardianScreen> {
  AppContainer get _c => AppScope.of(context);

  _Mode _mode = _Mode.check;

  // Check-a-charge state.
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _distance = TextEditingController();
  PriceCategory _category = PriceCategory.taxi;
  PriceCheckResult? _result;

  // Estimate-a-trip state.
  final TextEditingController _toSearch = TextEditingController();
  Position? _from;
  String? _fromLabel;
  bool _locating = false;
  Place? _to;
  List<Place> _results = const <Place>[];
  bool _searching = false;
  String? _searchError;
  bool _routing = false;
  RouteInfo? _route;

  @override
  void initState() {
    super.initState();
    if (_mode == _Mode.estimate) _locateFrom();
  }

  @override
  void dispose() {
    _amount.dispose();
    _distance.dispose();
    _toSearch.dispose();
    super.dispose();
  }

  void _switchMode(_Mode mode) {
    setState(() => _mode = mode);
    if (mode == _Mode.estimate && _from == null) _locateFrom();
  }

  // ------------------------------------------------------------------ check
  void _runCheck() {
    final double? amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount in ₹.')),
      );
      return;
    }
    final double? distance = double.tryParse(
        _distance.text.trim().replaceAll(',', '.'));
    FocusScope.of(context).unfocus();
    setState(() {
      _result = PriceGuard.check(
        category: _category,
        amount: amount,
        distanceKm: distance,
      );
    });
  }

  // ---------------------------------------------------------------- estimate
  Future<void> _locateFrom() async {
    setState(() => _locating = true);
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted) return;
      String? label;
      if (pos != null) {
        try {
          label = await _c.placesRepository
              .reverseGeocode(LatLng(pos.latitude, pos.longitude));
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _from = pos;
        _fromLabel = label;
        _locating = false;
      });
    } catch (_) {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _searchTo(String q) async {
    final String query = q.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final Position? pos = _from;
      final List<Place> places = await _c.placesRepository.search(
        query,
        location: pos == null
            ? null
            : LatLng(pos.latitude, pos.longitude),
      );
      if (!mounted) return;
      setState(() {
        _results = places;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e.toString();
        _searching = false;
      });
    }
  }

  Future<void> _selectTo(Place p) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _to = p;
      _results = const <Place>[];
      _route = null;
      _routing = true;
    });
    try {
      final Position? pos = _from;
      final RouteInfo r;
      if (pos == null) {
        r = RouteInfo(
          distanceMeters: 0,
          durationSeconds: 0,
          polyline: const <LatLng>[],
          provider: 'fallback',
        );
      } else {
        r = await _c.placesRepository.route(
          LatLng(pos.latitude, pos.longitude),
          p.coords,
        );
      }
      if (!mounted) return;
      setState(() {
        _route = r;
        _routing = false;
      });
    } catch (_) {
      if (!mounted) return;
      final Position? pos = _from;
      final double meters = pos == null
          ? 0
          : GeoUtils.distanceMeters(
              LatLng(pos.latitude, pos.longitude), p.coords);
      setState(() {
        _route = RouteInfo(
          distanceMeters: meters,
          durationSeconds: 0,
          polyline: const <LatLng>[],
          provider: 'fallback',
        );
        _routing = false;
      });
    }
  }

  Future<void> _navigateTo() async {
    final Place? p = _to;
    if (p == null) return;
    await _c.placesRepository.openInGoogleMaps(p.lat, p.lng, p.name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Guardian')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          SegmentedButton<_Mode>(
            segments: const <ButtonSegment<_Mode>>[
              ButtonSegment<_Mode>(
                value: _Mode.check,
                label: Text('Check a charge'),
                icon: Icon(Icons.receipt_long, size: 18),
              ),
              ButtonSegment<_Mode>(
                value: _Mode.estimate,
                label: Text('Estimate a trip'),
                icon: Icon(Icons.route, size: 18),
              ),
            ],
            selected: <_Mode>{_mode},
            onSelectionChanged: (Set<_Mode> s) => _switchMode(s.first),
          ),
          const SizedBox(height: 16),
          if (_mode == _Mode.check) ..._checkSection() else ..._estimateSection(),
        ],
      ),
    );
  }

  List<Widget> _checkSection() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return <Widget>[
      Text('Category',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: PriceCategory.values.map((PriceCategory c) {
          return ChoiceChip(
            label: Text(c.label),
            selected: _category == c,
            onSelected: (bool _) => setState(() => _category = c),
          );
        }).toList(),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        decoration: InputDecoration(
          labelText: 'Amount (₹)',
          prefixText: '₹ ',
          hintText: 'e.g. 800',
        ),
      ),
      if (_category.distanceBased) ...<Widget>[
        const SizedBox(height: 12),
        TextField(
          controller: _distance,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
          ],
          decoration: InputDecoration(
            labelText: 'Distance',
            suffixText: 'km',
            hintText: 'e.g. 5',
          ),
        ),
      ] else
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Reference basis: ${_category.unitHint}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 18),
      PrimaryButton(
        label: 'Check price',
        icon: Icons.analytics_outlined,
        onPressed: _runCheck,
      ),
      if (_result != null) ...<Widget>[
        const SizedBox(height: 20),
        _resultCard(_result!),
      ],
    ];
  }

  List<Widget> _estimateSection() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return <Widget>[
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.my_location, color: scheme.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _locating
                        ? 'Finding your location…'
                        : (_fromLabel ?? 'Location unavailable'),
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!_locating)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: 'Refresh my location',
                    onPressed: _locateFrom,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _from == null
                  ? 'Enable location to estimate fares from where you are.'
                  : 'From: your current position.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _toSearch,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          labelText: 'Destination',
          hintText: 'Search a place…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
        ),
        onSubmitted: _searchTo,
      ),
      if (_searchError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_searchError!, style: TextStyle(color: scheme.error)),
        )
      else if (_results.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                for (final Place p in _results.take(6))
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.place, color: scheme.primary),
                    title: Text(p.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: p.address == null
                        ? null
                        : Text(p.address!,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _selectTo(p),
                  ),
              ],
            ),
          ),
        ),
      if (_to != null) ...<Widget>[
        const SizedBox(height: 14),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.place, color: AppTheme.danger, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _to!.name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => setState(() {
                      _to = null;
                      _route = null;
                      _toSearch.clear();
                    }),
                  ),
                ],
              ),
              if (_routing)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Measuring the route…'),
                    ],
                  ),
                )
              else if (_route != null) ...<Widget>[
                Text(
                  'Distance: ${GeoUtils.formatDistance(_route!.distanceMeters)}'
                  '${_route!.isApproximate ? ' (straight-line estimate)' : ''}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                _fareRow(Icons.electric_rickshaw, 'Local auto (est.)',
                    PriceGuard.estimateAuto(_km)),
                const SizedBox(height: 6),
                _fareRow(Icons.local_taxi, 'Local taxi (est.)',
                    PriceGuard.estimateTaxi(_km)),
                const SizedBox(height: 6),
                Text(
                  'Auto ~ ₹${PriceGuard.autoPerKm.toStringAsFixed(0)}/km · '
                  'Taxi ~ ₹${PriceGuard.taxiPerKm.toStringAsFixed(0)}/km '
                  '(local street rates, rounded to ₹5). Rapido, Uber & Ola '
                  'prices are coming soon.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: PrimaryButton(
                        label: 'Navigate',
                        icon: Icons.navigation,
                        onPressed: _navigateTo,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: PrimaryButton(
                        label: 'Report concern',
                        outlined: true,
                        onPressed: () => context.push('/incidents/report'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
      const SizedBox(height: 12),
      AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Icon(Icons.info_outline, size: 18, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'All fares are estimates for guidance only — they are not '
                'proof of overcharging.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  double get _km =>
      (_route?.distanceMeters ?? 0) > 0 ? (_route!.distanceMeters / 1000) : 0;

  Widget _fareRow(IconData icon, String label, double fare) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Text(
          '₹${fare.round()}',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    );
  }

  Widget _resultCard(PriceCheckResult r) {
    final (IconData icon, Color color) = switch (r.verdict) {
      PriceVerdict.normal => (Icons.check_circle, AppTheme.success),
      PriceVerdict.low => (Icons.info_outline, AppTheme.warning),
      PriceVerdict.potentiallyHigh =>
        (Icons.warning_amber_rounded, AppTheme.danger),
      PriceVerdict.needsMoreInfo => (Icons.help_outline, AppTheme.warning),
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  r.headline,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (r.referenceText.isNotEmpty)
            Text(
              r.referenceText,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          const SizedBox(height: 8),
          Text(r.explanation, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: PrimaryButton(
                  label: 'I\'m fine',
                  outlined: true,
                  onPressed: () => setState(() => _result = null),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryButton(
                  label: 'Report concern',
                  danger: true,
                  onPressed: () => context.push('/incidents/report'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
