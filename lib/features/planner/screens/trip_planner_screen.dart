import 'package:flutter/material.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/local/trip_plan_store.dart';
import '../../../data/models/itinerary.dart';
import '../../../data/models/places.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/trip_plan.dart';

/// Trip Planner — build a realistic day-by-day plan with the AI, then keep it
/// fully editable on-device (reorder days, edit/add/remove items). Saved plans
/// also become the "active trip" that Home and Live Trip mode use.
class TripPlannerScreen extends StatefulWidget {
  const TripPlannerScreen({super.key});

  @override
  State<TripPlannerScreen> createState() => _TripPlannerScreenState();
}

class _TripPlannerScreenState extends State<TripPlannerScreen> {
  AppContainer get _c => AppScope.of(context);

  final TextEditingController _destination = TextEditingController();

  Place? _destPlace;
  List<Place> _searchResults = const <Place>[];
  bool _searchingDest = false;
  bool _destPicked = false;

  DateTime _startDate = DateTime.now().add(const Duration(days: 1));
  int _days = 3;
  int _partySize = 1;
  String _transport = 'car';
  String _budget = 'mid';
  String _style = 'balanced';
  final Set<String> _interests = <String>{};

  List<ItineraryDay> _plan = <ItineraryDay>[];
  bool _generating = false;
  String? _error;

  bool _storeLoaded = false;

  static const List<(String, String)> _budgets = <(String, String)>[
    ('budget', 'Budget'),
    ('mid', 'Mid-range'),
    ('luxury', 'Luxury'),
  ];

  static const List<(String, String)> _styles = <(String, String)>[
    ('relaxed', 'Relaxed'),
    ('balanced', 'Balanced'),
    ('packed', 'Packed'),
  ];

  static const List<(String, String)> _transports = <(String, String)>[
    ('car', 'Car'),
    ('bike', 'Bike'),
    ('auto', 'Auto'),
    ('taxi', 'Taxi'),
    ('public', 'Public transport'),
    ('train', 'Train'),
    ('flight', 'Flight'),
    ('walk', 'Walking'),
  ];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid != null) {
      await _c.tripPlanStore.loadFor(uid);
      _c.tripPlanStore.addListener(_onStore);
    }
    try {
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid != null) {
        final Profile? p = await _c.profileRepository.get(uid);
        if (mounted && p != null) {
          setState(() {
            _interests.addAll(p.interests);
            _budget = p.budget;
            _style = p.travelStyle;
            if (p.vehicle == 'bike' ||
                p.vehicle == 'car' ||
                p.vehicle == 'auto') {
              _transport = p.vehicle;
            }
          });
        }
      }
    } catch (_) {
      // Profile prefs are optional.
    }
    if (mounted) setState(() => _storeLoaded = true);
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.tripPlanStore.removeListener(_onStore);
    _destination.dispose();
    super.dispose();
  }

  Future<void> _searchDestination() async {
    final String q = _destination.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searchingDest = true;
      _searchResults = const <Place>[];
    });
    try {
      final List<Place> results =
          await _c.placesRepository.search(q, radiusMeters: 50000);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _searchingDest = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searchingDest = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Destination search failed. Try again.')),
      );
    }
  }

  void _pickDestination(Place p) {
    setState(() {
      _destPlace = p;
      _destPicked = true;
      _destination.text = p.name;
      _searchResults = const <Place>[];
    });
  }

  Future<void> _generate() async {
    final String destination = _destination.text.trim();
    if (destination.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a destination first.')),
      );
      return;
    }
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final List<ItineraryDay> plan = await _c.aiRepository.generateItinerary(
        destination: destination,
        days: _days,
        interests: _interests.toList(),
        budget: _budget,
        travelStyle: _style,
      );
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _generating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _generating = false;
      });
    }
  }

  Future<void> _save() async {
    if (_plan.isEmpty) return;
    final Place? dest = _destPlace;
    final TripPlan plan = TripPlan(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      destination: _destination.text.trim(),
      lat: dest?.lat ?? 0,
      lng: dest?.lng ?? 0,
      startDate: _startDate,
      days: _days,
      budget: _budget,
      travelStyle: _style,
      transport: _transport,
      partySize: _partySize,
      interests: _interests.toList(),
      plan: _plan,
      createdAt: DateTime.now(),
    );
    await _c.tripPlanStore.add(plan);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Trip plan saved for ${plan.destination}. It is now your active trip.')),
    );
  }

  Future<void> _setActive(TripPlan p) async {
    await _c.tripPlanStore.setActive(p.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Active trip: ${p.destination}')),
    );
  }

  Future<void> _deletePlan(TripPlan p) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete plan?'),
        content: Text('"${p.destination}" will be removed from this device.'),
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
    if (ok == true) await _c.tripPlanStore.remove(p.id);
  }

  Future<void> _openEditor(TripPlan p) async {
    final List<ItineraryDay>? edited = await Navigator.of(context)
        .push<List<ItineraryDay>>(MaterialPageRoute<List<ItineraryDay>>(
      builder: (BuildContext _) => _PlanEditor(plan: p.plan),
    ));
    if (edited == null || !mounted) return;
    await _c.tripPlanStore.update(TripPlan(
      id: p.id,
      destination: p.destination,
      lat: p.lat,
      lng: p.lng,
      startDate: p.startDate,
      days: p.days,
      budget: p.budget,
      travelStyle: p.travelStyle,
      transport: p.transport,
      partySize: p.partySize,
      interests: p.interests,
      plan: edited,
      createdAt: p.createdAt,
    ));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Plan updated.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Trip planner')),
      body: !_storeLoaded
          ? const LoadingView(message: 'Loading planner…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _formCard(scheme),
                const SizedBox(height: 12),
                _previewCard(scheme),
                const SizedBox(height: 12),
                _savedPlansCard(scheme),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _formCard(ColorScheme scheme) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Plan a trip',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'AI builds a realistic day-by-day plan from real destination '
            'knowledge. Verify details before you go.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _destination,
            decoration: InputDecoration(
              labelText: 'Destination',
              hintText: 'e.g. Jaipur, Rajasthan',
              prefixIcon: const Icon(Icons.place, size: 18),
              suffixIcon: _searchingDest
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      icon: const Icon(Icons.search, size: 18),
                      onPressed: _searchDestination,
                    ),
            ),
            onChanged: (_) {
              if (_destPicked) setState(() => _destPicked = false);
            },
            onSubmitted: (_) => _searchDestination(),
          ),
          if (_destPicked && _destPlace != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: <Widget>[
                  Icon(Icons.check_circle,
                      size: 16, color: AppTheme.success),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Location set: ${_destPlace!.name}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (_searchResults.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (BuildContext context, int i) {
                  final Place p = _searchResults[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place, size: 18),
                    title: Text(p.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: p.address == null
                        ? null
                        : Text(p.address!,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _pickDestination(p),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text('Start date: ${Fmt.date(_startDate)}'),
            trailing: const Icon(Icons.edit_calendar, size: 18),
            onTap: () async {
              final DateTime? picked = await showDatePicker(
                context: context,
                initialDate: _startDate,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 730)),
              );
              if (picked != null) setState(() => _startDate = picked);
            },
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: _stepper('Days', _days, 1, 30,
                    (int v) => setState(() => _days = v)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _stepper('Travelers', _partySize, 1, 20,
                    (int v) => setState(() => _partySize = v)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _transport,
            decoration: const InputDecoration(labelText: 'Transport'),
            items: <DropdownMenuItem<String>>[
              for (final (String id, String label) in _transports)
                DropdownMenuItem<String>(value: id, child: Text(label)),
            ],
            onChanged: (String? v) => setState(() => _transport = v ?? _transport),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _budget,
            decoration: const InputDecoration(labelText: 'Budget'),
            items: <DropdownMenuItem<String>>[
              for (final (String id, String label) in _budgets)
                DropdownMenuItem<String>(value: id, child: Text(label)),
            ],
            onChanged: (String? v) => setState(() => _budget = v ?? _budget),
          ),
          const SizedBox(height: 12),
          Text('Travel style',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              for (final (String id, String label) in _styles)
                ButtonSegment<String>(value: id, label: Text(label)),
            ],
            selected: <String>{_style},
            onSelectionChanged: (Set<String> sel) =>
                setState(() => _style = sel.first),
          ),
          const SizedBox(height: 12),
          Text('Interests',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String opt in kInterestOptions)
                FilterChip(
                  label: Text(opt),
                  selected: _interests.contains(opt),
                  onSelected: (bool sel) => setState(() {
                    if (sel) {
                      _interests.add(opt);
                    } else {
                      _interests.remove(opt);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _generating ? null : _generate,
              icon: _generating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_generating ? 'Generating plan…' : 'Generate plan'),
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(_error!,
                style: TextStyle(color: AppTheme.danger, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }

  Widget _stepper(
      String label, int value, int min, int max, ValueChanged<int> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Row(
          children: <Widget>[
            IconButton(
              onPressed:
                  value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Text('$value',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            IconButton(
              onPressed:
                  value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
      ],
    );
  }

  Widget _previewCard(ColorScheme scheme) {
    if (_plan.isEmpty) return const SizedBox.shrink();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('Generated plan',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              TextButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Save plan'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final ItineraryDay d in _plan) _dayTile(d),
        ],
      ),
    );
  }

  Widget _savedPlansCard(ColorScheme scheme) {
    final TripPlanStore store = _c.tripPlanStore;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Saved trips',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (store.plans.isEmpty)
          AppCard(
            child: Text(
              'No saved trips yet. Generate a plan above and save it — it '
              'will appear here and as your active trip on Home.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          for (final TripPlan p in store.plans.reversed) _savedPlanTile(p),
      ],
    );
  }

  Widget _savedPlanTile(TripPlan p) {
    final bool active = _c.tripPlanStore.active?.id == p.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          leading: Icon(
            active ? Icons.play_circle : Icons.map,
            color: active ? AppTheme.success : null,
          ),
          title: Text(p.destination,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(
            '${p.days} day${p.days == 1 ? '' : 's'} · ${Fmt.date(p.startDate)}'
            '${active ? ' · Active' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (String v) {
              if (v == 'active') _setActive(p);
              if (v == 'edit') _openEditor(p);
              if (v == 'delete') _deletePlan(p);
            },
            itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
              if (!active)
                const PopupMenuItem<String>(
                    value: 'active', child: Text('Set active')),
              const PopupMenuItem<String>(
                  value: 'edit', child: Text('Edit plan')),
              const PopupMenuItem<String>(
                  value: 'delete', child: Text('Delete')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dayTile(ItineraryDay d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text('Day ${d.day} — ${d.title}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        for (final ItineraryItem i in d.items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 64,
                  child: Text(i.time,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Expanded(
                  child: Text(
                    i.title,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Full-screen editor for a saved plan: reorder days and edit/add/remove
/// items. Returns the edited plan (or null to discard).
class _PlanEditor extends StatefulWidget {
  const _PlanEditor({required this.plan});

  final List<ItineraryDay> plan;

  @override
  State<_PlanEditor> createState() => _PlanEditorState();
}

class _PlanEditorState extends State<_PlanEditor> {
  late final List<ItineraryDay> _days = List<ItineraryDay>.from(widget.plan);

  void _moveDay(int index, int delta) {
    final int target = index + delta;
    if (target < 0 || target >= _days.length) return;
    setState(() {
      final ItineraryDay d = _days.removeAt(index);
      _days.insert(target, d);
    });
  }

  Future<void> _editItem(int dayIndex, int? itemIndex) async {
    final ItineraryDay day = _days[dayIndex];
    final ItineraryItem? existing =
        itemIndex == null ? null : day.items[itemIndex];
    final TextEditingController time =
        TextEditingController(text: existing?.time ?? '');
    final TextEditingController title =
        TextEditingController(text: existing?.title ?? '');
    final TextEditingController desc =
        TextEditingController(text: existing?.description ?? '');
    final TextEditingController cost =
        TextEditingController(text: existing?.cost ?? '');

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(existing == null ? 'Add item' : 'Edit item'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: time,
                decoration:
                    const InputDecoration(labelText: 'Time (e.g. 09:00)'),
              ),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Activity'),
              ),
              TextField(
                controller: desc,
                decoration: const InputDecoration(labelText: 'Details'),
              ),
              TextField(
                controller: cost,
                decoration: const InputDecoration(labelText: 'Cost (optional)'),
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
    if (saved != true || title.text.trim().isEmpty) return;
    final ItineraryItem item = ItineraryItem(
      time: time.text.trim(),
      title: title.text.trim(),
      description: desc.text.trim(),
      cost: cost.text.trim(),
    );
    setState(() {
      final List<ItineraryItem> items = List<ItineraryItem>.from(day.items);
      if (itemIndex == null) {
        items.add(item);
      } else {
        items[itemIndex] = item;
      }
      _days[dayIndex] = ItineraryDay(day: day.day, title: day.title, items: items);
    });
  }

  void _removeItem(int dayIndex, int itemIndex) {
    setState(() {
      final ItineraryDay day = _days[dayIndex];
      final List<ItineraryItem> items = List<ItineraryItem>.from(day.items)
        ..removeAt(itemIndex);
      _days[dayIndex] =
          ItineraryDay(day: day.day, title: day.title, items: items);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit plan'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(_days),
            child: const Text('Done'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            'Reorder days with the arrows, and tap an item to edit it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (int di = 0; di < _days.length; di++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            'Day ${_days[di].day} — ${_days[di].title}',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Move up',
                          icon: const Icon(Icons.arrow_upward, size: 18),
                          onPressed: di == 0 ? null : () => _moveDay(di, -1),
                        ),
                        IconButton(
                          tooltip: 'Move down',
                          icon: const Icon(Icons.arrow_downward, size: 18),
                          onPressed: di == _days.length - 1
                              ? null
                              : () => _moveDay(di, 1),
                        ),
                      ],
                    ),
                    for (int ii = 0; ii < _days[di].items.length; ii++)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.schedule, size: 16),
                        title: Text(
                            '${_days[di].items[ii].time}  ${_days[di].items[ii].title}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _removeItem(di, ii),
                        ),
                        onTap: () => _editItem(di, ii),
                      ),
                    TextButton.icon(
                      onPressed: () => _editItem(di, null),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add item'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
