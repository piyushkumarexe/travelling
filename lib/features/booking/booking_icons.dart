import 'package:flutter/material.dart';

import 'booking_models.dart';

/// Stable vector iconography for booking surfaces. These icons come from the
/// bundled Material font and therefore do not change appearance by device OS.
extension BookingCategoryIcon on BookingCategory {
  IconData get icon => switch (this) {
        BookingCategory.ride => Icons.local_taxi_outlined,
        BookingCategory.flight => Icons.flight_takeoff,
        BookingCategory.train => Icons.train_outlined,
        BookingCategory.bus => Icons.directions_bus_outlined,
        BookingCategory.hotel => Icons.hotel_outlined,
        BookingCategory.carRental => Icons.car_rental_outlined,
        BookingCategory.activities => Icons.local_activity_outlined,
      };
}

BookingCategory? bookingCategoryByName(String name) {
  for (final BookingCategory category in BookingCategory.values) {
    if (category.name == name) return category;
  }
  return null;
}

IconData providerIcon(String provider, {BookingCategory? category}) {
  final String value = provider.toLowerCase();
  if (value.contains('rapido') || value.contains('bike')) {
    return Icons.two_wheeler_outlined;
  }
  if (value.contains('uber') || value.contains('ola') ||
      value.contains('taxi')) {
    return Icons.local_taxi_outlined;
  }
  return category?.icon ?? Icons.travel_explore;
}
