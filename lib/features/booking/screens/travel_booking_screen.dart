import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../../../core/state/app_container.dart';
import '../booking_models.dart';
import '../booking_service.dart';

/// ✈️🚆🚌🏨🚗🎟️ Generic booking search screen for all non-ride
/// categories. Builds a BookingQuery, shows the honest summary sheet and
/// continues with the provider's VERIFIED official flow. No fares,
/// availability, ratings or confirmations are ever fabricated here.
class TravelBookingScreen extends StatefulWidget {
  const TravelBookingScreen({super.key, required this.category});

  final BookingCategory category;

  static bool isSupported(BookingCategory c) =>
      c != BookingCategory.ride;

  @override
  State<TravelBookingScreen> createState() => _TravelBookingScreenState();
}

class _TravelBookingScreenState extends State<TravelBookingScreen> {
  AppContainer get _c => AppScope.of(context);

  final TextEditingController _from = TextEditingController();
  final TextEditingController _to = TextEditingController();
  DateTime _date = DateTime.now().add(const Duration(days: 1));
  DateTime? _returnDate;
  int _pax = 1;
  int _rooms = 1;
  String _class = 'E';
  BookingProvider? _launching;

  bool get _needsFrom => widget.category == BookingCategory.flight ||
      widget.category == BookingCategory.train ||
      widget.category == BookingCategory.bus ||
      widget.category == BookingCategory.carRental ||
      widget.category == BookingCategory.activities;
  bool get _needsTo => widget.category != BookingCategory.activities;
  bool get _needsReturn => widget.category == BookingCategory.flight ||
      widget.category == BookingCategory.carRental ||
      widget.category == BookingCategory.hotel;
  bool get _needsPax => widget.category != BookingCategory.carRental;
  bool get _needsClass => widget.category == BookingCategory.flight ||
      widget.category == BookingCategory.train;
  bool get _needsRooms => widget.category == BookingCategory.hotel;

  @override
  Widget build(BuildContext context) {
    final List<BookingProvider> providers =
        BookingProviders.forCategory(widget.category);
    return Scaffold(
      appBar: AppBar(
          title: Text('${widget.category.emoji} Book '
              '${widget.category.label}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          ..._formFields(),
          const SizedBox(height: 14),
          Text('Continue with a provider',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          for (final BookingProvider p in providers) _providerCard(p),
          const SizedBox(height: 8),
          Text(
            'Search and booking happen on the provider\'s official site/app. '
            'Tourism shows no prices, seats or availability — the provider '
            'does.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text('TRAVEL-BOOKING-HUB-2026-09-13-01',
                style: TextStyle(fontSize: 10, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  List<Widget> _formFields() {
    return <Widget>[
      if (_needsFrom)
        TextField(
          controller: _from,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: widget.category == BookingCategory.hotel
                ? 'Destination (or use below)'
                : widget.category == BookingCategory.carRental
                    ? 'Pickup location'
                    : widget.category == BookingCategory.activities
                        ? 'City (or use current location)'
                        : 'From (city or station/airport code)',
            hintText: switch (widget.category) {
              BookingCategory.flight => 'DEL',
              BookingCategory.train => 'New Delhi (NDLS)',
              _ => null,
            },
            border: const OutlineInputBorder(),
          ),
        ),
      if (_needsTo && widget.category != BookingCategory.activities &&
          widget.category != BookingCategory.hotel)
        const SizedBox(height: 10),
      if (_needsTo && widget.category != BookingCategory.activities)
        TextField(
          controller: _to,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: widget.category == BookingCategory.carRental
                ? 'Drop-off location (optional)'
                : 'To (city or station/airport code)',
            hintText: switch (widget.category) {
              BookingCategory.flight => 'BOM',
              BookingCategory.train => 'Varanasi (BSB)',
              BookingCategory.hotel => 'e.g. Varanasi',
              _ => null,
            },
            border: const OutlineInputBorder(),
          ),
        ),
      if (widget.category == BookingCategory.activities) ...<Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _to,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Destination city',
                    border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Use my current city (GPS)',
              onPressed: _useCurrentLocation,
              icon: const Icon(Icons.my_location),
            ),
          ],
        ),
      ],
      const SizedBox(height: 10),
      _dateTile(
        label: widget.category == BookingCategory.hotel
            ? 'Check-in'
            : widget.category == BookingCategory.carRental
                ? 'Pickup date'
                : 'Date',
        value: _date,
        onPick: (DateTime d) => setState(() => _date = d),
      ),
      if (_needsReturn)
        _dateTile(
          label: widget.category == BookingCategory.hotel
              ? 'Check-out'
              : widget.category == BookingCategory.carRental
                  ? 'Return date'
                  : 'Return (optional)',
          value: _returnDate,
          optional: true,
          onPick: (DateTime d) => setState(() => _returnDate = d),
        ),
      if (_needsPax)
        _stepperTile('Passengers', _pax, 1, 9,
            (int v) => setState(() => _pax = v)),
      if (_needsRooms)
        _stepperTile(
            'Rooms', _rooms, 1, 5, (int v) => setState(() => _rooms = v)),
      if (_needsClass)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              if (widget.category == BookingCategory.flight) ...<ButtonSegment<String>>[
                const ButtonSegment<String>(value: 'E', label: Text('Economy')),
                const ButtonSegment<String>(
                    value: 'PE', label: Text('Premium')),
                const ButtonSegment<String>(
                    value: 'B', label: Text('Business')),
              ] else ...<ButtonSegment<String>>[
                const ButtonSegment<String>(value: 'E', label: Text('General')),
                const ButtonSegment<String>(value: 'B', label: Text('Tatkal')),
              ],
            ],
            selected: <String>{_class},
            onSelectionChanged: (Set<String> s) =>
                setState(() => _class = s.first),
          ),
        ),
      if (widget.category == BookingCategory.flight)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(value: 'O', label: Text('One-way')),
              ButtonSegment<String>(value: 'R', label: Text('Round trip')),
            ],
            selected: <String>{_tripType},
            onSelectionChanged: (Set<String> s) =>
                setState(() => _tripType = s.first),
          ),
        ),
    ];
  }

  String _tripType = 'O';

  Future<void> _useCurrentLocation() async {
    final Position? p = await _c.locationService.currentPosition();
    if (!mounted) return;
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📍 Location unavailable — type the city instead.')));
      return;
    }
    // FreeGeoClient has no reverse geocoding; label honestly with coords.
    setState(() {
      _from.text =
          'Current location (${p.latitude.toStringAsFixed(3)}, '
          '${p.longitude.toStringAsFixed(3)})';
    });
  }

  Widget _dateTile({
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime> onPick,
    bool optional = false,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.calendar_month, size: 18),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      subtitle: Text(value == null
          ? 'Not set'
          : DateFormat('EEE, d MMM yyyy').format(value)),
      trailing: value == null
          ? TextButton(onPressed: () => _pickDate(onPick),
              child: const Text('Set'))
          : TextButton(
              onPressed: () => setState(() => optional ? onPick(value) : onPick(value)),
              child: const Text('Change')),
    );
  }

  Future<void> _pickDate(ValueChanged<DateTime> onPick) async {
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d != null) onPick(d);
  }

  Widget _stepperTile(
      String label, int value, int min, int max, ValueChanged<int> onChanged) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.people, size: 18),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            onPressed: value > min ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Text('$value',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w800)),
          IconButton(
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }

  Widget _providerCard(BookingProvider p) {
    final bool busy = _launching?.providerId == p.providerId;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: busy ? null : () => _confirm(p),
        leading: Text(p.emoji, style: const TextStyle(fontSize: 22)),
        title: Text(p.providerName,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(p.handoffNote,
            style: const TextStyle(fontSize: 11.5)),
        trailing: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.chevron_right),
      ),
    );
  }

  Future<void> _confirm(BookingProvider p) async {
    // Validation: forms that matter must be filled before hand-off.
    if (p.appDeepLinkBuilder != null &&
        widget.category == BookingCategory.flight &&
        (_from.text.trim().isEmpty || _to.text.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter From and To (airport codes) to continue.')));
      return;
    }
    if (p.appDeepLinkBuilder != null &&
        widget.category == BookingCategory.hotel &&
        _to.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a destination to search on Booking.com.')));
      return;
    }
    final BookingQuery q = BookingQuery(
      fromName: _from.text.trim().isEmpty ? null : _from.text.trim(),
      toName: _to.text.trim().isEmpty ? null : _to.text.trim(),
      date: BookingProviders.formatIso(_date),
      returnDate: _returnDate == null
          ? null
          : BookingProviders.formatIso(_returnDate!),
      passengers: _pax,
      rooms: _rooms,
      travelClass: _needsClass ? _class : null,
      tripType: _tripType,
    );

    final bool? go = await showModalBottomSheet<bool>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('${p.emoji} Continue with ${p.providerName}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 10),
              if (_needsFrom && _from.text.trim().isNotEmpty)
                _row('From', _from.text.trim()),
              if (_to.text.trim().isNotEmpty) _row('To', _to.text.trim()),
              _row('Date', DateFormat('d MMM yyyy').format(_date)),
              if (_returnDate != null)
                _row('Return', DateFormat('d MMM yyyy').format(_returnDate!)),
              if (_needsPax) _row('Passengers', '$_pax'),
              if (_needsRooms) _row('Rooms', '$_rooms'),
              if (_needsClass) _row('Class', _class),
              const SizedBox(height: 8),
              Text(p.handoffNote, style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text('Continue with ${p.providerName}'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (go != true) return;

    setState(() => _launching = p);
    final BookingLaunchResult result =
        await _c.bookingService.continueWithProvider(p, q);
    if (!mounted) return;
    setState(() => _launching = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(describeLaunch(result))));
    if (result == BookingLaunchResult.appNotInstalled ||
        result == BookingLaunchResult.opened ||
        result == BookingLaunchResult.openedApp ||
        result == BookingLaunchResult.openedWeb) {
      await _offerSave(p, q);
    }
  }

  Future<void> _offerSave(BookingProvider p, BookingQuery q) async {
    if (!mounted) return;
    final bool? save = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Save booking reference?'),
        content: Text(
            'Did you complete a booking with ${p.providerName}? Save its '
            'reference (PNR / booking id) here so it stays with your trip. '
            'Tourism never marks an external booking as confirmed — you '
            'control the status.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save booking')),
        ],
      ),
    );
    if (save != true || !mounted) return;
    await _saveSheet(p, q);
  }

  Future<void> _saveSheet(BookingProvider p, BookingQuery q) async {
    final TextEditingController refC = TextEditingController();
    final TextEditingController notesC = TextEditingController();
    String status = 'saved';
    final bool? ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Save ${p.providerName} booking',
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 10),
            TextField(
              controller: refC,
              decoration: const InputDecoration(
                labelText: 'Booking reference / PNR (from the provider)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: notesC,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: status,
              decoration: const InputDecoration(
                  labelText: 'Status', border: OutlineInputBorder()),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(value: 'saved', child: Text('Saved (not confirmed yet)')),
                DropdownMenuItem<String>(value: 'confirmed', child: Text('Confirmed (I verified it)')),
                DropdownMenuItem<String>(value: 'cancelled', child: Text('Cancelled')),
              ],
              onChanged: (String? v) => status = v ?? 'saved',
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save to my bookings'),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final bool saved = await _c.bookingService.saveBooking(BookingRef(
      id: _c.bookingService.newBookingId(),
      userId: _c.authRepository.currentUser?.uid ?? '',
      category: widget.category.name,
      provider: p.providerName,
      serviceType: _needsClass ? _class : (q.serviceType ?? ''),
      status: status,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      tripId: _c.tripPlanStore.active?.id,
      origin: _from.text.trim().isEmpty ? null : _from.text.trim(),
      destination: _to.text.trim().isEmpty ? null : _to.text.trim(),
      bookingDate: q.date,
      externalReference: refC.text.trim().isEmpty ? null : refC.text.trim(),
      notes: notesC.text.trim().isEmpty ? null : notesC.text.trim(),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(saved
            ? 'Booking reference saved.'
            : (_c.bookingService.lastError ??
                'Could not save — check your internet.'))));
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
                width: 100,
                child: Text(k,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}
