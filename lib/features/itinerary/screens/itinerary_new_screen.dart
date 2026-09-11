import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../data/models/itinerary.dart';
import '../../../data/models/profile.dart';

/// AI itinerary generator: destination, days, interests, budget, style.
/// Generates a real plan from the backend AI, lets the user regenerate,
/// then saves it to Firestore.
class ItineraryNewScreen extends StatefulWidget {
  const ItineraryNewScreen({super.key});

  @override
  State<ItineraryNewScreen> createState() => _ItineraryNewScreenState();
}

class _ItineraryNewScreenState extends State<ItineraryNewScreen> {
  AppContainer get _c => AppScope.of(context);

  final TextEditingController _destinationController = TextEditingController();
  int _days = 3;
  final Set<String> _interests = <String>{};
  String _budget = 'mid';
  String _style = 'balanced';

  List<ItineraryDay> _plan = <ItineraryDay>[];
  bool _generating = false;
  bool _previewing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pre-fill interests from the profile when available.
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid != null) {
      _c.profileRepository.get(uid).then((Profile? p) {
        if (mounted && p != null) {
          setState(() {
            _interests.addAll(p.interests);
            _budget = p.budget;
            _style = p.travelStyle;
          });
        }
      }).catchError((Object _) {});
    }
  }

  Future<void> _generate() async {
    final String destination = _destinationController.text.trim();
    final String? destError =
        Validators.requiredText(destination, max: 120);
    if (destError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(destError)));
      return;
    }
    setState(() {
      _generating = true;
      _error = null;
      _previewing = false;
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
        _previewing = true;
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
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null || _plan.isEmpty) return;
    setState(() => _generating = true);
    try {
      final Itinerary itinerary = Itinerary(
        id: '',
        uid: uid,
        destination: _destinationController.text.trim(),
        days: _days,
        interests: _interests.toList(),
        budget: _budget,
        travelStyle: _style,
        plan: _plan,
        createdAt: DateTime.now(),
      );
      final String id = await _c.itinerariesRepository.create(uid, itinerary);
      if (!mounted) return;
      context.pushReplacement('/itineraries/$id');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _error = 'Could not save the itinerary: $e';
      });
    }
  }

  @override
  void dispose() {
    _destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New AI itinerary'),
        actions: <Widget>[
          if (_previewing)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Regenerate'),
                onPressed: _generating ? null : _generate,
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Trip details',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _destinationController,
                  decoration: const InputDecoration(
                    labelText: 'Destination',
                    hintText: 'e.g. Rishikesh, Kyoto, Lisbon…',
                    prefixIcon: Icon(Icons.public),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Text(
                      'Days: $_days',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Slider(
                        value: _days.toDouble(),
                        min: 1,
                        max: 10,
                        divisions: 9,
                        label: '$_days days',
                        onChanged: (double v) =>
                            setState(() => _days = v.round()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Interests',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final String opt in kInterestOptions)
                      ChoiceChip(
                        label: Text(opt),
                        selected: _interests.contains(opt),
                        onSelected: (bool sel) {
                          setState(() {
                            if (sel) {
                              _interests.add(opt);
                            } else {
                              _interests.remove(opt);
                            }
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _budget,
                        decoration: const InputDecoration(
                            labelText: 'Budget'),
                        items: <DropdownMenuItem<String>>[
                          for (final String b in kBudgetLevels)
                            DropdownMenuItem<String>(
                              value: b,
                              child: Text(b
                                  .replaceAll('_', ' ')
                                  .toUpperCase()),
                            ),
                        ],
                        onChanged: (String? v) =>
                            setState(() => _budget = v ?? 'mid'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _style,
                        decoration:
                            const InputDecoration(labelText: 'Style'),
                        items: <DropdownMenuItem<String>>[
                          for (final String s in kTravelStyles)
                            DropdownMenuItem<String>(
                              value: s,
                              child: Text(s
                                  .replaceAll('_', ' ')
                                  .toUpperCase()),
                            ),
                        ],
                        onChanged: (String? v) =>
                            setState(() => _style = v ?? 'balanced'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                PrimaryButton(
                  label: _previewing
                      ? 'Save itinerary'
                      : 'Generate itinerary',
                  icon: _previewing ? Icons.save : Icons.auto_awesome,
                  loading: _generating,
                  onPressed: _previewing ? _save : _generate,
                ),
                if (!_previewing) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    'Tap “Generate” to create the plan, review it, then save. '
                    'You can regenerate as many times as you like before saving.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
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
          ],
          if (_generating && !_previewing) ...<Widget>[
            const SizedBox(height: 20),
            const SectionHeader(title: 'Generating…'),
            const SkeletonList(count: 3, height: 140),
          ],
          if (_previewing) ...<Widget>[
            const SizedBox(height: 20),
            SectionHeader(title: 'Your plan · ${_plan.length} day(s)'),
            if (_plan.isNotEmpty)
              AppCard(
                padding: const EdgeInsets.all(4),
                child: DefaultTabController(
                  length: _plan.length,
                  initialIndex: 0,
                  child: Column(
                    children: <Widget>[
                      TabBar(
                        isScrollable: true,
                        labelColor: scheme.primary,
                        unselectedLabelColor: scheme.onSurfaceVariant,
                        tabs: <Widget>[
                          for (int i = 0; i < _plan.length; i++)
                            Tab(text: 'Day ${i + 1}'),
                        ],
                      ),
                      const Divider(height: 1),
                      SizedBox(
                        height: 320,
                        child: TabBarView(
                          children: <Widget>[
                            for (int i = 0; i < _plan.length; i++)
                              _dayView(_plan[i]),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _dayView(ItineraryDay day) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (day.items.isEmpty) {
      return Center(
        child: Text(
          'No items listed for ${day.title}.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: day.items.length,
      separatorBuilder: (BuildContext context, int i) =>
          const Divider(height: 20),
      itemBuilder: (BuildContext context, int i) {
        final ItineraryItem item = day.items[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                item.time.isEmpty ? '—' : item.time,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (item.description.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(item.description,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                  if (item.cost.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(item.cost,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.primary)),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
