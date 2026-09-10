import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/itinerary.dart';

/// Saved AI itineraries (persisted in Firestore).
class ItineraryListScreen extends StatefulWidget {
  const ItineraryListScreen({super.key});

  @override
  State<ItineraryListScreen> createState() => _ItineraryListScreenState();
}

class _ItineraryListScreenState extends State<ItineraryListScreen> {
  AppContainer get _c => AppScope.of(context);

  List<Itinerary> _items = const <Itinerary>[];
  bool _loading = true;
  String? _error;
  StreamSubscription<List<Itinerary>>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    _sub = _c.itinerariesRepository
        .watchMine(uid)
        .listen((List<Itinerary> items) {
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    }, onError: (Object e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    });
  }

  Future<void> _delete(Itinerary it) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete itinerary?'),
        content: Text(
          '“${it.destination}” (${it.days} day${it.days > 1 ? 's' : ''}) will '
          'be permanently deleted.',
        ),
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
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid == null) return;
      await _c.itinerariesRepository.remove(uid, it.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My itineraries')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/itineraries/new'),
        icon: const Icon(Icons.travel_explore),
        label: const Text('New itinerary'),
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: SkeletonList(count: 3, height: 150),
            )
          : _error != null
              ? ErrorState(message: _error!, onRetry: _listen)
              : _items.isEmpty
                  ? EmptyState(
                      icon: Icons.travel_explore,
                      title: 'No itineraries yet',
                      message:
                          'Generate your first AI itinerary — destination, days, interests, budget and style.',
                      actionLabel: 'Create itinerary',
                      onAction: () => context.go('/itineraries/new'),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      itemCount: _items.length,
                      itemBuilder: (BuildContext context, int i) {
                        final Itinerary it = _items[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: AppCard(
                            onTap: () => context.go('/itineraries/${it.id}'),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Text(
                                        it.destination,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                                fontWeight: FontWeight.w800),
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      onSelected: (String v) {
                                        if (v == 'delete') _delete(it);
                                      },
                                      itemBuilder: (BuildContext ctx) =>
                                          const <PopupMenuEntry<String>>[
                                        PopupMenuItem<String>(
                                            value: 'delete',
                                            child: Text(
                                                'Delete')),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${it.days} day${it.days > 1 ? 's' : ''} · '
                                  '${it.budget} budget · ${it.travelStyle} style',
                                  style:
                                      Theme.of(context).textTheme.bodyMedium,
                                ),
                                if (it.interests.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: <Widget>[
                                      for (final String i2 in it.interests)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primaryContainer
                                                .withOpacity(0.5),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Text(i2,
                                              style: const TextStyle(
                                                  fontSize: 11)),
                                        ),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Text(
                                  'Created ${Fmt.date(it.createdAt)} · '
                                  '${it.plan.length} day(s) planned',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
