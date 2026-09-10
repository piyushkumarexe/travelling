import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/itinerary.dart';
import '../../../data/models/places.dart';

/// Saved itinerary detail: day tabs, per-day items, delete, open in map.
class ItineraryDetailScreen extends StatefulWidget {
  const ItineraryDetailScreen({super.key, required this.id});

  final String id;

  @override
  State<ItineraryDetailScreen> createState() => _ItineraryDetailScreenState();
}

class _ItineraryDetailScreenState extends State<ItineraryDetailScreen> {
  AppContainer get _c => AppScope.of(context);

  String? _uid() => _c.authRepository.currentUser?.uid;

  Itinerary? _itinerary;
  bool _loading = true;
  String? _error;
  bool _openingMap = false;
  StreamSubscription<Itinerary?>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _c.itinerariesRepository
        .watchOne(_uid() ?? '', widget.id)
        .listen((Itinerary? it) {
      if (!mounted) return;
      setState(() {
        _itinerary = it;
        _loading = false;
      });
    }, onError: (Object e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    });
  }

  Future<void> _delete() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete itinerary?'),
        content: const Text('This cannot be undone.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final String? uid = _uid();
      if (uid == null) return;
      await _c.itinerariesRepository.remove(uid, widget.id);
      if (mounted) context.go('/itineraries');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _openDestinationOnMap() async {
    final Itinerary? it = _itinerary;
    if (it == null) return;
    setState(() => _openingMap = true);
    try {
      final List<Place> places =
          await _c.placesRepository.search(it.destination);
      if (!mounted) return;
      if (places.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Could not locate that destination on the map.')),
        );
        return;
      }
      final Place p = places.first;
      context.go('/map?lat=${p.lat}&lng=${p.lng}&name=${Uri.encodeComponent(p.name)}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Map lookup failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _openingMap = false);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Itinerary')),
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: SkeletonList(count: 3, height: 140),
        ),
      );
    }
    if (_error != null || _itinerary == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Itinerary')),
        body: ErrorState(message: _error ?? 'Itinerary not found.'),
      );
    }
    final Itinerary it = _itinerary!;
    return Scaffold(
      appBar: AppBar(
        title: Text(it.destination),
        actions: <Widget>[
          IconButton(
            tooltip: 'Open destination on map',
            icon: const Icon(Icons.map),
            onPressed: _openingMap ? null : _openDestinationOnMap,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
            onPressed: _delete,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: <Widget>[
                _metaChip('${it.days} days'),
                const SizedBox(width: 8),
                _metaChip('${it.budget} budget'),
                const SizedBox(width: 8),
                _metaChip('${it.travelStyle} style'),
                const Spacer(),
                Text(
                  Fmt.date(it.createdAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            child: DefaultTabController(
              length: it.plan.length,
              child: Column(
                children: <Widget>[
                  TabBar(
                    isScrollable: true,
                    labelColor: scheme.primary,
                    unselectedLabelColor: scheme.onSurfaceVariant,
                    tabs: <Widget>[
                      for (int i = 0; i < it.plan.length; i++)
                        Tab(text: 'Day ${i + 1}'),
                    ],
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: TabBarView(
                      children: <Widget>[
                        for (int i = 0; i < it.plan.length; i++)
                          _dayView(it.plan[i]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(String text) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _dayView(ItineraryDay day) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (day.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No items listed for ${day.title}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: day.items.length,
      separatorBuilder: (BuildContext context, int i) => const Divider(),
      itemBuilder: (BuildContext context, int i) {
        final ItineraryItem item = day.items[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withOpacity(0.5),
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
