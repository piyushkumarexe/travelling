import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/state/app_container.dart';
import '../../../core/utils/geo.dart';
import '../../../data/models/places.dart';
import '../../../data/repositories/places_repository.dart';
import '../booking_models.dart';
import '../booking_service.dart';
import '../price_compare.dart';

/// One-tap price comparison: every platform for this query, side by side,
/// cheapest first, each with the arithmetic that produced the number and a
/// button that opens the platform's VERIFIED official flow.
///
/// The numbers are ESTIMATES (see price_compare.dart) — the sheet says so at
/// the top and on every row, because the only place a real, bookable fare
/// exists is the provider itself. That is also why every row can be opened
/// in one tap.
Future<void> showPriceCompareSheet(
  BuildContext context, {
  required BookingCategory category,
  required BookingQuery query,
  required List<BookingProvider> providers,
  required DateTime date,
  required int pax,
  double? distanceKm,
  double? minutes,
  int nights = 1,
  String? serviceType,
  String? trainClass,
  String? busClass,
  String? hotelTier,
  TripEstimate? trip,
}) async {
  // Personal calibration stays on-device. It makes the approximation improve
  // after the traveller tells us what the provider actually showed, without
  // scraping private apps or pretending Tourism has a partner fare API.
  final Map<String, double> learned = <String, double>{};
  if (category == BookingCategory.ride) {
    final BookingService service = AppScope.of(context).bookingService;
    for (final BookingProvider p in providers) {
      learned[p.providerId] =
          await service.rideFareFactor(p.providerId, serviceType ?? 'cab');
    }
    if (!context.mounted) return;
  }
  final List<PlatformQuote> quotes = category == BookingCategory.ride
      ? PriceCompare.forRide(
          providers: providers,
          query: query,
          distanceKm: distanceKm,
          minutes: minutes,
          vehicle: serviceType ?? 'cab',
          learnedFactors: learned,
        )
      : PriceCompare.forTravel(
          category: category,
          providers: providers,
          query: query,
          pax: pax,
          date: date,
          distanceKm: distanceKm,
          nights: nights,
          trainClass: trainClass,
          busClass: busClass,
          hotelTier: hotelTier,
        );
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => _PriceCompareBody(
      category: category,
      query: query,
      providers: providers,
      quotes: quotes,
      trip: trip,
      distanceKm: distanceKm,
      pax: pax,
      serviceType: serviceType,
    ),
  );
}

/// Great-circle distance between two place names, or null when either side
/// cannot be geocoded. Used to price inter-city trips — the caller shows
/// "no estimate" rows when this comes back null rather than guessing.
Future<double?> resolveDistanceKm(
  BuildContext context,
  String? fromName,
  String? toName,
) async {
  final String a = (fromName ?? '').trim();
  final String b = (toName ?? '').trim();
  if (a.length < 2 || b.length < 2) return null;
  try {
    final PlacesRepository repo = AppScope.of(context).placesRepository;
    final List<Place> hits = await repo
        .search(b, radiusMeters: 200000)
        .timeout(const Duration(seconds: 12));
    if (hits.isEmpty) return null;
    final List<Place> fromHits = await repo
        .search(a, radiusMeters: 200000)
        .timeout(const Duration(seconds: 12));
    if (fromHits.isEmpty) return null;
    final Place to = hits.first;
    final Place from = fromHits.first;
    return GeoUtils.distanceMetersLL(from.lat, from.lng, to.lat, to.lng) / 1000;
  } catch (_) {
    return null;
  }
}

class _PriceCompareBody extends StatelessWidget {
  const _PriceCompareBody({
    required this.category,
    required this.query,
    required this.providers,
    required this.quotes,
    required this.trip,
    required this.distanceKm,
    required this.pax,
    required this.serviceType,
  });

  final BookingCategory category;
  final BookingQuery query;
  final List<BookingProvider> providers;
  final List<PlatformQuote> quotes;
  final TripEstimate? trip;
  final double? distanceKm;
  final int pax;
  final String? serviceType;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final NumberFormat inr = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    final double? km = distanceKm;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.94,
      builder: (BuildContext context, ScrollController scroll) =>
          ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: <Widget>[
          Text('${category.emoji} Compare ${category.label} prices',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            km == null
                ? 'No distance available for this pair, so these are the '
                    'platforms you can check — open any of them for the '
                    'live fare.'
                : 'Estimated totals for ${km.toStringAsFixed(0)} km, '
                    '$pax traveller(s). Tourism does NOT have live '
                    'fares — each row opens the platform where the real, '
                    'bookable price is.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          if (trip != null) _tripCard(context, inr, trip!),
          for (int i = 0; i < quotes.length; i++)
            _quoteCard(context, inr, quotes[i], isCheapest: i == 0),
          const SizedBox(height: 10),
          Text(
            'Ride ranges include pickup/base, road distance, route time, '
            'platform fee and a time-of-day buffer. They learn locally when '
            'you enter the actual shown fare. Real prices still move with '
            'live demand, pickup distance, tolls and offers — only an official '
            'partner fare API could show them inside Tourism, so always '
            'confirm on the provider before paying.',
            style: theme.textTheme.bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  Widget _tripCard(BuildContext context, NumberFormat inr, TripEstimate t) {
    final ThemeData theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('🧳 Whole-trip budget (${t.days} day(s), ${t.pax} pax)',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            _line('Travel', inr.format(t.travelLow), inr.format(t.travelHigh)),
            _line('Stay', inr.format(t.stayLow), inr.format(t.stayHigh)),
            _line('Food', inr.format(t.foodLow), inr.format(t.foodHigh)),
            _line('Local transport', inr.format(t.localLow),
                inr.format(t.localHigh)),
            _line('Activities', inr.format(t.activitiesLow),
                inr.format(t.activitiesHigh)),
            const Divider(),
            Row(
              children: <Widget>[
                Text('Total',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(
                  '${inr.format(t.totalLow)} – ${inr.format(t.totalHigh)}',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text('≈ ${inr.format(t.perDayLow)} – ${inr.format(t.perDayHigh)} '
                'per day for the whole group'),
            const SizedBox(height: 6),
            Text(t.basis, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _line(String label, String low, String high) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Text('$low – $high'),
        ],
      ),
    );
  }

  Widget _quoteCard(
    BuildContext context,
    NumberFormat inr,
    PlatformQuote q, {
    required bool isCheapest,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final BookingProvider? provider = providers
        .where((BookingProvider p) => p.providerId == q.providerId)
        .firstOrNull;
    final bool priced = q.hasPrice;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(q.emoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(q.providerName,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                if (isCheapest && priced)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('CHEAPEST',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: scheme.onTertiaryContainer)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (priced)
              Text(
                '${inr.format(q.low)} – ${inr.format(q.high)}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              )
            else
              Text('— no estimate —',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(q.basis, style: theme.textTheme.bodySmall),
            if (q.note.isNotEmpty) ...<Widget>[
              const SizedBox(height: 2),
              Text(q.note,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(q.confidence.label,
                      style: const TextStyle(fontSize: 10.5)),
                ),
                const Spacer(),
                if (provider != null)
                  FilledButton.tonalIcon(
                    onPressed: () => _open(context, provider),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Check live price'),
                  ),
              ],
            ),
            if (category == BookingCategory.ride && q.hasPrice)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _recordActualFare(context, q),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('Actual fare different? Improve estimate'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _recordActualFare(
      BuildContext context, PlatformQuote quote) async {
    final TextEditingController amount = TextEditingController();
    final int? actual = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('${quote.providerName} actual fare'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Provider app me jo final fare dikh raha hai woh enter '
                'karein. Ye sirf is phone par estimate improve karega.'),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                prefixText: '₹ ',
                labelText: 'Actual shown fare',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final int? value = int.tryParse(amount.text.trim());
              if (value != null && value >= 10 && value <= 10000) {
                Navigator.pop(dialogContext, value);
              }
            },
            child: const Text('Save & learn'),
          ),
        ],
      ),
    );
    amount.dispose();
    if (actual == null || !context.mounted) return;
    await AppScope.of(context).bookingService.recordActualRideFare(
          providerId: quote.providerId,
          serviceType: serviceType ?? 'cab',
          estimatedMid: quote.mid,
          actualFare: actual,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Saved ₹$actual. Future ${quote.providerName} '
          '${serviceType ?? 'cab'} estimates will learn from it.'),
    ));
  }

  Future<void> _open(BuildContext context, BookingProvider p) async {
    final BookingService service = AppScope.of(context).bookingService;
    final BookingLaunchResult r = await service.continueWithProvider(p, query);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('${p.providerName}: ${describeLaunch(r).isEmpty ? 'Opening…' : describeLaunch(r)}')),
    );
  }
}
