import 'package:flutter/material.dart';

import '../../data/models/places.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';

/// Compact place row used in Explore, Home and Map lists.
class PlaceCard extends StatelessWidget {
  const PlaceCard({
    super.key,
    required this.place,
    this.distance,
    this.onTap,
    this.trailing,
  });

  final Place place;
  final String? distance;
  final VoidCallback? onTap;

  /// Optional trailing widget (e.g. a "Show on map" button) rendered after
  /// the distance chip.
  final Widget? trailing;

  static IconData iconFor(Place place) {
    if (place.isEmergency) {
      if (place.types.contains('hospital')) return Icons.local_hospital;
      if (place.types.contains('police_station')) return Icons.local_police;
      if (place.types.contains('fire_station')) return Icons.local_fire_department;
      return Icons.medical_services;
    }
    if (place.isTourist) return Icons.attractions;
    if (place.isFood) return Icons.restaurant;
    if (place.types.contains('park')) return Icons.park;
    if (place.types.contains('museum')) return Icons.museum;
    if (place.types.contains('hotel') || place.types.contains('lodging')) {
      return Icons.hotel;
    }
    if (place.types.contains('shopping_mall') ||
        place.types.contains('store')) {
      return Icons.storefront;
    }
    if (place.types.contains('cafe')) return Icons.coffee;
    return Icons.place;
  }

  static Color colorFor(BuildContext context, Place place) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (place.isEmergency) return AppTheme.danger;
    if (place.isTourist) return scheme.primary;
    if (place.isFood) return AppTheme.warning;
    return scheme.tertiary;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = colorFor(context, place);
    final String subtitle = <String>[
      if (place.address != null && place.address!.isNotEmpty)
        place.address!,
    ].join(' · ');
    final String ratingText = place.rating != null
        ? '★ ${place.rating!.toStringAsFixed(1)}'
            '${place.userRatingCount != null ? ' (${place.userRatingCount})' : ''}'
        : (place.primaryType ?? '').replaceAll('_', ' ');

    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(iconFor(place), color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  place.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                const SizedBox(height: 4),
                Text(
                  ratingText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
          if (distance != null)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                distance!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
