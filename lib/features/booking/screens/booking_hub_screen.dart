import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../booking_icons.dart';
import '../booking_models.dart';
import '../booking_service.dart';

/// 🧳 TRAVEL BOOKING HUB — one universal screen to continue into official
/// booking flows for rides, flights, trains, buses, hotels, car rentals and
/// activities. Renders instantly (no provider data needed), keeps saved
/// booking references, and shows the temporary build tag for verification.
class BookingHubScreen extends StatefulWidget {
  const BookingHubScreen({super.key});

  @override
  State<BookingHubScreen> createState() => _BookingHubScreenState();
}

class _BookingHubScreenState extends State<BookingHubScreen> {
  AppContainer get _c => AppScope.of(context);

  @override
  void initState() {
    super.initState();
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid != null) {
      _c.bookingService.start(uid);
      _c.tripPlanStore.loadFor(uid).catchError((Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<BookingCategory> cats = BookingCategory.values;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.airplane_ticket_outlined),
            SizedBox(width: 8),
            Text('Travel Booking Hub'),
          ],
        ),
      ),
      body: ListenableBuilder(
        listenable: _c.bookingService,
        builder: (BuildContext context, _) {
          final List<BookingRef> bookings = _c.bookingService.bookings;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              Text('Book rides, flights, trains, buses, hotels and '
                  'activities.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.05,
                children: <Widget>[
                  for (final BookingCategory c in cats)
                    _categoryTile(c),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Booking and payment happen on each provider\'s official '
                'app/site. Tourism stores only the references you save.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Text('My saved bookings',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const Spacer(),
                  if (bookings.isNotEmpty)
                    TextButton(
                      onPressed: () => _confirmClearRecents(),
                      child: const Text('Clear recents',
                          style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (_c.bookingService.loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: LinearProgressIndicator(),
                )
              else if (bookings.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      'No bookings saved yet. After booking with a provider, '
                      'tap "Save booking" to keep the reference (PNR / id) '
                      'here — linked to your active trip when one is set.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                )
              else
                for (final BookingRef b in bookings) _bookingTile(b),
              const SizedBox(height: 18),
              const Center(
                child: Text('TRAVEL-BOOKING-HUB-2026-09-13-01',
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _categoryTile(BookingCategory c) {
    final bool isRide = c == BookingCategory.ride;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (isRide) {
            context.push('/booking/ride');
          } else {
            context.push('/booking/travel',
                extra: <String, String>{'category': c.name});
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(c.icon,
                  size: 30, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 6),
              Text(
                c.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookingTile(BookingRef b) {
    final String tripName = _c.bookingService.tripName(b.tripId);
    final Color statusColor = switch (b.status) {
      'confirmed' => AppTheme.success,
      'cancelled' => AppTheme.danger,
      _ => AppTheme.warning,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          bookingCategoryByName(b.category)?.icon ?? Icons.travel_explore,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          '${b.provider}'
          '${b.destination == null || b.destination!.isEmpty ? '' : ' → ${b.destination}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${b.bookingDate ?? ''}'
          '${b.externalReference == null ? '' : ' · ref ${b.externalReference}'}'
          '${tripName.isEmpty ? '' : ' · trip: $tripName'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(b.status,
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: statusColor)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Delete saved reference',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () =>
                  unawaitedDelete(b.id),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> unawaitedDelete(String id) async {
    await _c.bookingService.deleteBooking(id);
  }

  Future<void> _confirmClearRecents() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Clear recent locations?'),
        content: const Text(
            'Removes the saved pickup/destination suggestions from this '
            'device. This does not affect your saved bookings.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      await _c.bookingService.clearRecentLocations();
    }
  }
}
