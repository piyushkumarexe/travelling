import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/uiverse.dart';
import '../traveller_toolkit_engine.dart';

/// Six travel utilities in one fast, state-preserving hub. Core calculations
/// are offline; Safety Mode deliberately reuses the app's real GPS/SOS stack.
class TravellerToolkitScreen extends StatefulWidget {
  const TravellerToolkitScreen({super.key});

  @override
  State<TravellerToolkitScreen> createState() => _TravellerToolkitScreenState();
}

class _TravellerToolkitScreenState extends State<TravellerToolkitScreen> {
  static const String _prefix = 'travellerToolkit.v1.';

  ToolkitTool? _active;
  bool _loaded = false;

  // Packing
  int _packingDays = 3;
  TripStyle _tripStyle = TripStyle.leisure;
  Climate _climate = Climate.mixed;
  Set<String> _packed = <String>{};
  List<String> _customPacking = <String>[];

  // Countdown
  final TextEditingController _destination = TextEditingController();
  DateTime _departure = DateTime.now().add(const Duration(days: 7));
  Set<String> _departureDone = <String>{};
  Timer? _clock;

  // Budget
  final TextEditingController _budget = TextEditingController(text: '30000');
  final TextEditingController _travellers = TextEditingController(text: '2');
  final TextEditingController _budgetDays = TextEditingController(text: '3');

  // Phrasebook / converter
  final TextEditingController _phraseSearch = TextEditingController();
  final TextEditingController _convertValue = TextEditingController(text: '10');
  Conversion _conversion = Conversion.kmToMiles;

  // Automatic Safety Agent. Values are read from the device and existing app
  // safety services; no slider or pretend status is shown as real telemetry.
  final Battery _battery = Battery();
  DeviceSafetySignals? _safetySignals;
  DateTime? _safetyScannedAt;
  bool _safetyScanning = false;
  bool _startingSafetyMode = false;
  bool _didBindSafetyServices = false;
  AppContainer? _container;

  @override
  void initState() {
    super.initState();
    _load();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      if (_active == ToolkitTool.countdown) setState(() {});
      if (_active == ToolkitTool.safety) unawaited(_scanSafety());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didBindSafetyServices) return;
    _didBindSafetyServices = true;
    final AppContainer c = AppScope.of(context);
    _container = c;
    c.settings.addListener(_safetyServiceChanged);
    c.liveLocationShare.addListener(_safetyServiceChanged);
    unawaited(_scanSafety());
  }

  void _safetyServiceChanged() {
    if (mounted && _active == ToolkitTool.safety) unawaited(_scanSafety());
  }

  @override
  void dispose() {
    final AppContainer? c = _container;
    if (_didBindSafetyServices && c != null) {
      c.settings.removeListener(_safetyServiceChanged);
      c.liveLocationShare.removeListener(_safetyServiceChanged);
    }
    _clock?.cancel();
    _destination.dispose();
    _budget.dispose();
    _travellers.dispose();
    _budgetDays.dispose();
    _phraseSearch.dispose();
    _convertValue.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      _packingDays = p.getInt('${_prefix}packingDays') ?? 3;
      _tripStyle = TripStyle.values.elementAtOrNull(
              p.getInt('${_prefix}tripStyle') ?? 0) ??
          TripStyle.leisure;
      _climate = Climate.values.elementAtOrNull(
              p.getInt('${_prefix}climate') ?? 3) ??
          Climate.mixed;
      _packed = (p.getStringList('${_prefix}packed') ?? <String>[]).toSet();
      _customPacking =
          p.getStringList('${_prefix}customPacking') ?? <String>[];
      _destination.text = p.getString('${_prefix}destination') ?? '';
      final int? departureMs = p.getInt('${_prefix}departure');
      if (departureMs != null) {
        final DateTime saved = DateTime.fromMillisecondsSinceEpoch(departureMs);
        if (saved.isAfter(DateTime.now().subtract(const Duration(days: 2)))) {
          _departure = saved;
        }
      }
      _departureDone =
          (p.getStringList('${_prefix}departureDone') ?? <String>[]).toSet();
      _budget.text = p.getString('${_prefix}budget') ?? '30000';
      _travellers.text = p.getString('${_prefix}travellers') ?? '2';
      _budgetDays.text = p.getString('${_prefix}budgetDays') ?? '3';
    } catch (_) {
      // Defaults are a fully working offline fallback.
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _savePacking() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await Future.wait(<Future<bool>>[
      p.setInt('${_prefix}packingDays', _packingDays),
      p.setInt('${_prefix}tripStyle', _tripStyle.index),
      p.setInt('${_prefix}climate', _climate.index),
      p.setStringList('${_prefix}packed', _packed.toList()),
      p.setStringList('${_prefix}customPacking', _customPacking),
    ]);
  }

  Future<void> _saveCountdown() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await Future.wait(<Future<bool>>[
      p.setString('${_prefix}destination', _destination.text.trim()),
      p.setInt('${_prefix}departure', _departure.millisecondsSinceEpoch),
      p.setStringList('${_prefix}departureDone', _departureDone.toList()),
    ]);
  }

  Future<void> _saveBudget() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await Future.wait(<Future<bool>>[
      p.setString('${_prefix}budget', _budget.text),
      p.setString('${_prefix}travellers', _travellers.text),
      p.setString('${_prefix}budgetDays', _budgetDays.text),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        leading: _active == null
            ? null
            : IconButton(
                tooltip: 'All tools',
                onPressed: () => setState(() => _active = null),
                icon: const Icon(Icons.arrow_back),
              ),
        title: Text(_active?.title ?? 'Traveller Toolkit'),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _active == null
              ? _dashboard()
              : KeyedSubtree(
                  key: ValueKey<ToolkitTool>(_active!),
                  child: _toolBody(_active!),
                ),
        ),
      ),
    );
  }

  Widget _dashboard() {
    final ColorScheme s = Theme.of(context).colorScheme;
    return ListView(
      key: const ValueKey<String>('toolkit-dashboard'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: <Widget>[
        UiverseSurface(
          accent: s.primary,
          padding: const EdgeInsets.all(18),
          child: Row(
            children: <Widget>[
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: <Color>[
                      AppTheme.brandStart,
                      AppTheme.brandEnd,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: s.primary.withValues(alpha: 0.28),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(Icons.travel_explore,
                    color: Colors.white, size: 27),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('6 advanced tools · offline-first',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 17)),
                    const SizedBox(height: 3),
                    Text(
                      'Plan, pack, communicate and run an automatic device safety scan.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: s.onSurfaceVariant, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.96,
          children: <Widget>[
            _toolTile(ToolkitTool.packing, const Color(0xFF7C3AED),
                Icons.luggage_outlined, 'Saved checklist'),
            _toolTile(ToolkitTool.countdown, const Color(0xFF0284C7),
                Icons.timer_outlined, _countdownBadge()),
            _toolTile(ToolkitTool.budget, const Color(0xFF059669),
                Icons.pie_chart_outline, 'Group-ready'),
            _toolTile(ToolkitTool.phrases, const Color(0xFFEA580C),
                Icons.translate, '${TravellerToolkitEngine.phrases.length} phrases'),
            _toolTile(ToolkitTool.safety, const Color(0xFFDC2626),
                Icons.health_and_safety_outlined, 'Automatic device scan'),
            _toolTile(ToolkitTool.converter, const Color(0xFFDB2777),
                Icons.swap_horiz, '10 conversions'),
          ],
        ),
      ],
    );
  }

  Widget _toolTile(
      ToolkitTool tool, Color color, IconData icon, String badge) {
    return UiverseIconTile(
      icon: icon,
      title: tool.title,
      subtitle: tool.subtitle,
      color: color,
      badge: badge,
      onTap: () {
        setState(() => _active = tool);
        if (tool == ToolkitTool.safety) unawaited(_scanSafety());
      },
    );
  }

  String _countdownBadge() {
    final CountdownResult c =
        TravellerToolkitEngine.countdown(DateTime.now(), _departure);
    return c.urgency == CountdownUrgency.passed ? 'Set trip' : c.headline;
  }

  Widget _toolBody(ToolkitTool tool) => switch (tool) {
        ToolkitTool.packing => _packingTool(),
        ToolkitTool.countdown => _countdownTool(),
        ToolkitTool.budget => _budgetTool(),
        ToolkitTool.phrases => _phrasebookTool(),
        ToolkitTool.safety => _safetyTool(),
        ToolkitTool.converter => _converterTool(),
      };

  // ---------------------------------------------------------------------
  // SMART PACKING
  // ---------------------------------------------------------------------

  List<PackingItem> get _packingItems => <PackingItem>[
        ...TravellerToolkitEngine.packingList(
          days: _packingDays,
          style: _tripStyle,
          climate: _climate,
        ),
        for (final String name in _customPacking)
          PackingItem(name: name, category: 'Custom'),
      ];

  Widget _packingTool() {
    final List<PackingItem> items = _packingItems;
    final int done = items.where((PackingItem i) => _packed.contains(i.id)).length;
    final double progress = items.isEmpty ? 0 : done / items.length;
    final Map<String, List<PackingItem>> groups = <String, List<PackingItem>>{};
    for (final PackingItem i in items) {
      groups.putIfAbsent(i.category, () => <PackingItem>[]).add(i);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: <Widget>[
        UiverseSurface(
          accent: const Color(0xFF7C3AED),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: DropdownButtonFormField<TripStyle>(
                      initialValue: _tripStyle,
                      decoration: const InputDecoration(labelText: 'Trip type'),
                      items: <DropdownMenuItem<TripStyle>>[
                        for (final TripStyle v in TripStyle.values)
                          DropdownMenuItem<TripStyle>(
                              value: v, child: Text(v.label)),
                      ],
                      onChanged: (TripStyle? v) {
                        if (v == null) return;
                        setState(() => _tripStyle = v);
                        unawaited(_savePacking());
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<Climate>(
                      initialValue: _climate,
                      decoration: const InputDecoration(labelText: 'Weather'),
                      items: <DropdownMenuItem<Climate>>[
                        for (final Climate v in Climate.values)
                          DropdownMenuItem<Climate>(
                              value: v, child: Text(v.label)),
                      ],
                      onChanged: (Climate? v) {
                        if (v == null) return;
                        setState(() => _climate = v);
                        unawaited(_savePacking());
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Text('$_packingDays day${_packingDays == 1 ? '' : 's'}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  Expanded(
                    child: Slider(
                      value: _packingDays.toDouble(),
                      min: 1,
                      max: 30,
                      divisions: 29,
                      label: '$_packingDays',
                      onChanged: (double v) =>
                          setState(() => _packingDays = v.round()),
                      onChangeEnd: (_) => unawaited(_savePacking()),
                    ),
                  ),
                  Text('$done/${items.length}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ],
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(value: progress, minHeight: 8),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: UiverseButton(
                label: 'Add item',
                icon: Icons.add,
                compact: true,
                onPressed: _addPackingItem,
              ),
            ),
            const SizedBox(width: 10),
            TextButton.icon(
              onPressed: _packed.isEmpty
                  ? null
                  : () {
                      setState(() => _packed.clear());
                      unawaited(_savePacking());
                    },
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset checks'),
            ),
          ],
        ),
        for (final MapEntry<String, List<PackingItem>> group in groups.entries)
          _packingGroup(group.key, group.value),
      ],
    );
  }

  Widget _packingGroup(String title, List<PackingItem> items) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: UiverseSurface(
        padding: const EdgeInsets.symmetric(vertical: 6),
        accent: const Color(0xFF7C3AED),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w900)),
            ),
            for (final PackingItem item in items)
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _packed.contains(item.id),
                title: Text(
                  item.displayName,
                  style: TextStyle(
                    decoration: _packed.contains(item.id)
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                secondary: item.category == 'Custom'
                    ? IconButton(
                        tooltip: 'Remove',
                        onPressed: () {
                          setState(() {
                            _customPacking.remove(item.name);
                            _packed.remove(item.id);
                          });
                          unawaited(_savePacking());
                        },
                        icon: const Icon(Icons.close, size: 18),
                      )
                    : null,
                onChanged: (bool? v) {
                  setState(() => v == true
                      ? _packed.add(item.id)
                      : _packed.remove(item.id));
                  unawaited(_savePacking());
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _addPackingItem() async {
    final TextEditingController c = TextEditingController();
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext d) => AlertDialog(
        title: const Text('Add packing item'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Camera batteries'),
          onSubmitted: (String v) => Navigator.pop(d, v.trim()),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(d, c.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    c.dispose();
    if (value == null || value.isEmpty || !mounted) return;
    setState(() {
      if (!_customPacking.contains(value)) _customPacking.add(value);
    });
    unawaited(_savePacking());
  }

  // ---------------------------------------------------------------------
  // COUNTDOWN
  // ---------------------------------------------------------------------

  Widget _countdownTool() {
    final CountdownResult c =
        TravellerToolkitEngine.countdown(DateTime.now(), _departure);
    final List<DepartureTask> tasks =
        TravellerToolkitEngine.departureTasks(DateTime.now(), _departure);
    final int done = tasks.where((DepartureTask t) =>
        _departureDone.contains(t.title)).length;
    final Color urgency = switch (c.urgency) {
      CountdownUrgency.planned => const Color(0xFF0284C7),
      CountdownUrgency.soon => AppTheme.warning,
      CountdownUrgency.today || CountdownUrgency.now => AppTheme.danger,
      CountdownUrgency.passed => Theme.of(context).colorScheme.outline,
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: <Widget>[
        UiverseSurface(
          accent: urgency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _destination,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Destination / trip name',
                  prefixIcon: Icon(Icons.place_outlined),
                ),
                onChanged: (_) => unawaited(_saveCountdown()),
              ),
              const SizedBox(height: 12),
              Text(c.headline,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: urgency,
                    letterSpacing: -0.8,
                  )),
              const SizedBox(height: 4),
              Text(DateFormat('EEE, d MMM yyyy · h:mm a').format(_departure)),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: UiverseButton(
                      label: 'Set departure',
                      icon: Icons.event,
                      compact: true,
                      onPressed: _pickDeparture,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('$done/${tasks.length} ready',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        UiverseSurface(
          accent: urgency,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: <Widget>[
              for (final DepartureTask task in tasks)
                CheckboxListTile(
                  value: _departureDone.contains(task.title),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(task.title),
                  subtitle: task.dueNow && !_departureDone.contains(task.title)
                      ? const Text('Due now',
                          style: TextStyle(
                              color: AppTheme.warning,
                              fontWeight: FontWeight.w700))
                      : null,
                  secondary: task.dueNow
                      ? const Icon(Icons.notifications_active_outlined,
                          size: 19, color: AppTheme.warning)
                      : const Icon(Icons.schedule, size: 19),
                  onChanged: (bool? v) {
                    setState(() => v == true
                        ? _departureDone.add(task.title)
                        : _departureDone.remove(task.title));
                    unawaited(_saveCountdown());
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickDeparture() async {
    final DateTime now = DateTime.now();
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: _departure.isAfter(now) ? _departure : now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 730)),
    );
    if (date == null || !mounted) return;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_departure),
    );
    if (time == null || !mounted) return;
    setState(() {
      _departure = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      _departureDone.clear();
    });
    unawaited(_saveCountdown());
  }

  // ---------------------------------------------------------------------
  // BUDGET SPLITTER
  // ---------------------------------------------------------------------

  BudgetSplit get _split => TravellerToolkitEngine.splitBudget(
        total: double.tryParse(_budget.text) ?? 0,
        travellers: int.tryParse(_travellers.text) ?? 1,
        days: int.tryParse(_budgetDays.text) ?? 1,
      );

  Widget _budgetTool() {
    final BudgetSplit b = _split;
    final NumberFormat money = NumberFormat.currency(
        locale: 'en_IN', symbol: '₹', decimalDigits: 0);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: <Widget>[
        UiverseSurface(
          accent: const Color(0xFF059669),
          child: Column(
            children: <Widget>[
              _numberField(_budget, 'Total trip budget', '₹', 8),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(child: _numberField(_travellers, 'Travellers', null, 3)),
                  const SizedBox(width: 10),
                  Expanded(child: _numberField(_budgetDays, 'Days', null, 3)),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(child: _metric('Per person', money.format(b.perPerson))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _metric('Person / day',
                          money.format(b.perPersonPerDay))),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        UiverseSurface(
          accent: const Color(0xFF059669),
          child: Column(
            children: <Widget>[
              _budgetRow(Icons.hotel_outlined, 'Stay', 35, b.stay, money),
              _budgetRow(Icons.directions_transit, 'Transport', 25,
                  b.transport, money),
              _budgetRow(Icons.restaurant_outlined, 'Food', 20, b.food, money),
              _budgetRow(Icons.local_activity_outlined, 'Activities', 10,
                  b.activities, money),
              _budgetRow(Icons.health_and_safety_outlined, 'Emergency buffer',
                  10, b.emergencyBuffer, money),
              const Divider(),
              Text(
                'Suggested planning split, not a spending limit. Adjust in '
                'Expense Guard once real bookings arrive.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _numberField(TextEditingController c, String label, String? prefix,
      int maxLength) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        LengthLimitingTextInputFormatter(maxLength),
      ],
      decoration: InputDecoration(labelText: label, prefixText: prefix),
      onChanged: (_) {
        setState(() {});
        unawaited(_saveBudget());
      },
    );
  }

  Widget _metric(String label, String value) {
    final ColorScheme s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: s.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: <Widget>[
          Text(value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _budgetRow(IconData icon, String label, int percent, double value,
      NumberFormat f) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 21, color: const Color(0xFF059669)),
          const SizedBox(width: 10),
          Expanded(child: Text('$label · $percent%')),
          Text(f.format(value),
              style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // PHRASEBOOK
  // ---------------------------------------------------------------------

  Widget _phrasebookTool() {
    final List<TravelPhrase> phrases =
        TravellerToolkitEngine.searchPhrases(_phraseSearch.text);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: TextField(
            controller: _phraseSearch,
            decoration: InputDecoration(
              labelText: 'Search English, Hindi, Hinglish or category',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _phraseSearch.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      onPressed: () {
                        _phraseSearch.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: phrases.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.manage_search,
                            size: 52, color: Color(0xFFEA580C)),
                        const SizedBox(height: 12),
                        const Text('No phrase matched',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 5),
                        Text(
                          'Try a simple intent like “doctor”, “meter”, '
                          '“kya hua”, “hotel” or “emergency”.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            itemCount: phrases.length,
            itemBuilder: (BuildContext context, int index) {
              final TravelPhrase p = phrases[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: UiverseSurface(
                  accent: const Color(0xFFEA580C),
                  padding: const EdgeInsets.all(13),
                  onTap: () => _copyPhrase(p),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(p.english,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800)),
                                ),
                                Text(p.category,
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFFEA580C),
                                        fontWeight: FontWeight.w800)),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(p.hindi,
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700)),
                            Text(p.roman,
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.copy_outlined, size: 19),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _copyPhrase(TravelPhrase p) async {
    await Clipboard.setData(ClipboardData(text: '${p.hindi}\n${p.roman}'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied: ${p.roman}')),
    );
  }

  // ---------------------------------------------------------------------
  // AUTOMATIC TOURIST SAFETY AGENT
  // ---------------------------------------------------------------------

  Future<void> _scanSafety() async {
    if (_safetyScanning) return;
    final AppContainer? c = _container;
    if (c == null) return;
    setState(() => _safetyScanning = true);

    int? batteryPercent;
    BatteryState batteryState = BatteryState.unknown;
    bool locationEnabled = false;
    LocationPermission permission = LocationPermission.denied;
    bool recentLocation = false;
    try {
      batteryPercent = (await _battery.batteryLevel).clamp(0, 100);
      batteryState = await _battery.batteryState;
    } catch (_) {
      // Unknown stays explicit in the UI; no percentage is fabricated.
    }
    try {
      locationEnabled = await c.locationService.isServiceEnabled();
      permission = await c.locationService.checkPermission();
      if (locationEnabled &&
          permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever) {
        final Position? fix = await c.locationService.bestRecentFix(
          maxAge: const Duration(minutes: 15),
        );
        recentLocation = fix != null;
      }
    } catch (_) {
      // The individual location rows explain the unavailable state.
    }
    final DateTime now = DateTime.now();
    final DeviceSafetySignals signals = DeviceSafetySignals(
      batteryPercent: batteryPercent,
      batteryCharging: batteryState == BatteryState.charging ||
          batteryState == BatteryState.full,
      afterDark: now.hour >= 20 || now.hour < 6,
      locationServiceEnabled: locationEnabled,
      locationPermissionGranted: permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse,
      hasRecentLocation: recentLocation,
      liveSharing: c.liveLocationShare.active,
      hasSosContact: c.settings.sosContactPhone.trim().isNotEmpty,
      offlineEmergencySms: c.settings.offlineEmergencySms,
      powerOffSafety: c.settings.powerOffSafety,
    );
    if (!mounted) return;
    setState(() {
      _safetySignals = signals;
      _safetyScannedAt = now;
      _safetyScanning = false;
    });
  }

  Widget _safetyTool() {
    final DeviceSafetySignals? signal = _safetySignals;
    if (signal == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(_safetyScanning
                ? 'Safety Agent is reading this device…'
                : 'Device safety signals are unavailable.'),
            if (!_safetyScanning)
              TextButton.icon(
                onPressed: _scanSafety,
                icon: const Icon(Icons.refresh),
                label: const Text('Scan again'),
              ),
          ],
        ),
      );
    }
    final SafetyBrief brief =
        TravellerToolkitEngine.assessAutomaticSafety(signal);
    final Color color = switch (brief.level) {
      SafetyLevel.prepared => AppTheme.success,
      SafetyLevel.elevated => AppTheme.warning,
      SafetyLevel.high => AppTheme.danger,
    };
    final String label = switch (brief.level) {
      SafetyLevel.prepared => 'Device ready',
      SafetyLevel.elevated => 'Action recommended',
      SafetyLevel.high => 'Fix before travel',
    };
    final String batteryLabel = signal.batteryPercent == null
        ? 'Unavailable'
        : '${signal.batteryPercent}%${signal.batteryCharging ? ' · charging' : ''}';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: <Widget>[
        UiverseSurface(
          accent: color,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 62,
                    height: 62,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: color.withValues(alpha: 0.35), width: 2),
                    ),
                    child: Text('${brief.score}',
                        style: TextStyle(
                            color: color,
                            fontSize: 22,
                            fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(Icons.auto_awesome, color: color, size: 18),
                            const SizedBox(width: 6),
                            Text(label,
                                style: TextStyle(
                                    color: color,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w900)),
                          ],
                        ),
                        Text(
                          'Automatic scan · ${DateFormat('h:mm a').format(_safetyScannedAt!)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Run scan again',
                    onPressed: _safetyScanning ? null : _scanSafety,
                    icon: _safetyScanning
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final String action in brief.actions.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.arrow_right, size: 19, color: color),
                      Expanded(child: Text(action)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        UiverseSurface(
          accent: Theme.of(context).colorScheme.primary,
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            children: <Widget>[
              _agentSignal(Icons.battery_5_bar, 'Real battery', batteryLabel,
                  signal.batteryPercent != null &&
                      (signal.batteryPercent! > 30 || signal.batteryCharging)),
              _agentSignal(
                  signal.afterDark
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                  'Local time',
                  signal.afterDark ? 'After dark' : 'Daylight',
                  !signal.afterDark),
              _agentSignal(Icons.my_location, 'GPS readiness',
                  signal.hasRecentLocation ? 'Recent fix ready' : 'Needs attention',
                  signal.hasRecentLocation),
              _agentSignal(Icons.contact_emergency_outlined, 'SOS contact',
                  signal.hasSosContact ? 'Configured' : 'Missing',
                  signal.hasSosContact),
              _agentSignal(Icons.share_location_outlined, 'Live sharing',
                  signal.liveSharing ? 'Active now' : 'Off',
                  signal.liveSharing),
              _agentSignal(Icons.sms_outlined, 'Offline emergency SMS',
                  signal.offlineEmergencySms ? 'Enabled' : 'Disabled',
                  signal.offlineEmergencySms),
              _agentSignal(Icons.power_settings_new, 'Power-off safety',
                  signal.powerOffSafety ? 'Enabled' : 'Disabled',
                  signal.powerOffSafety),
            ],
          ),
        ),
        const SizedBox(height: 12),
        UiverseButton(
          label: signal.liveSharing
              ? 'SAFETY MODE ACTIVE'
              : signal.hasSosContact
                  ? 'START SAFETY MODE'
                  : 'SET UP SOS CONTACT',
          icon: signal.liveSharing
              ? Icons.verified_user_outlined
              : Icons.shield_outlined,
          loading: _startingSafetyMode,
          onPressed: signal.liveSharing
              ? () => context.push('/safety')
              : signal.hasSosContact
                  ? _startSafetyMode
                  : () => context.push('/safety'),
        ),
        const SizedBox(height: 8),
        Text(
          signal.liveSharing
              ? 'Your live position is being shared through the existing SOS service.'
              : 'Safety Mode obtains a real GPS fix and starts live sharing with your saved SOS contact.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: UiverseButton(
                label: 'Call 112',
                icon: Icons.local_police_outlined,
                danger: true,
                compact: true,
                onPressed: () => _callNumber('112'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: UiverseButton(
                label: 'Cyber 1930',
                icon: Icons.security,
                compact: true,
                onPressed: () => _callNumber('1930'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => context.push('/safety'),
          icon: const Icon(Icons.tune),
          label: const Text('OPEN FULL SAFETY CENTER'),
        ),
        const SizedBox(height: 16),
        const Text('Scam response cards',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        for (final ScamCard card in TravellerToolkitEngine.scamCards)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: UiverseSurface(
              accent: AppTheme.warning,
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                title: Text(card.title,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                children: <Widget>[
                  Text(card.action),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(card.hindiScript,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: card.hindiScript));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Safety phrase copied')));
                        }
                      },
                      icon: const Icon(Icons.copy, size: 17),
                      label: const Text('Copy phrase'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _agentSignal(
      IconData icon, String title, String value, bool ready) {
    final Color color = ready ? AppTheme.success : AppTheme.warning;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(ready ? Icons.check_circle : Icons.info_outline,
              color: color, size: 17),
          const SizedBox(width: 5),
          Text(value,
              style: TextStyle(color: color, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Future<void> _startSafetyMode() async {
    final AppContainer c = _container!;
    setState(() => _startingSafetyMode = true);
    bool started = false;
    try {
      started = await c.liveLocationShare.start(
        reason: 'tourist-safety-agent',
        travelerName:
            c.authRepository.currentUser?.displayName?.trim().isNotEmpty == true
                ? c.authRepository.currentUser!.displayName!.trim()
                : 'Traveler',
      );
    } catch (_) {
      started = false;
    }
    if (!mounted) return;
    setState(() => _startingSafetyMode = false);
    await _scanSafety();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(started
          ? 'Safety Mode started. Live location sharing is active.'
          : 'Safety Mode could not start. Check SOS contact, sign-in and GPS.'),
    ));
  }

  Future<void> _callNumber(String number) async {
    final bool opened = await launchUrl(Uri.parse('tel:$number'));
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the phone app for $number')));
    }
  }

  // ---------------------------------------------------------------------
  // CONVERTER
  // ---------------------------------------------------------------------

  Widget _converterTool() {
    final double input = double.tryParse(_convertValue.text) ?? 0;
    final double output = TravellerToolkitEngine.convert(input, _conversion);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: <Widget>[
        UiverseSurface(
          accent: const Color(0xFFDB2777),
          child: Column(
            children: <Widget>[
              DropdownButtonFormField<Conversion>(
                initialValue: _conversion,
                decoration: const InputDecoration(labelText: 'Conversion'),
                isExpanded: true,
                items: <DropdownMenuItem<Conversion>>[
                  for (final Conversion v in Conversion.values)
                    DropdownMenuItem<Conversion>(
                        value: v, child: Text(v.label)),
                ],
                onChanged: (Conversion? v) {
                  if (v != null) setState(() => _conversion = v);
                },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _convertValue,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true, signed: true),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
                  LengthLimitingTextInputFormatter(12),
                ],
                decoration: InputDecoration(
                  labelText: _conversion.from,
                  prefixIcon: const Icon(Icons.calculate_outlined),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 18),
              const Icon(Icons.keyboard_double_arrow_down,
                  color: Color(0xFFDB2777)),
              const SizedBox(height: 8),
              Text(
                _formatNumber(output),
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                  color: Color(0xFFDB2777),
                ),
              ),
              Text(_conversion.to,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              UiverseButton(
                label: 'Copy result',
                icon: Icons.copy,
                compact: true,
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: '${_formatNumber(output)} ${_conversion.to}'));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Converted result copied')));
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Includes distance, temperature, luggage weight, fuel volume and '
          'fuel economy. Conversions are mathematical and work offline.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  static String _formatNumber(double v) {
    if (!v.isFinite) return '—';
    if (v.abs() >= 1000) return v.toStringAsFixed(1);
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(v.abs() < 10 ? 3 : 2);
  }
}

enum ToolkitTool {
  packing('Smart Packing', 'Weather-aware list that remembers progress'),
  countdown('Trip Countdown', 'Departure clock and readiness checks'),
  budget('Group Budget', 'Split a trip by person, day and category'),
  phrases('India Phrasebook', '145 Hindi essentials with Hinglish search'),
  safety('Safety Agent', 'Automatic battery, GPS, SOS and sharing checks'),
  converter('Travel Converter', 'Distance, weather, bags and fuel');

  const ToolkitTool(this.title, this.subtitle);
  final String title;
  final String subtitle;
}
