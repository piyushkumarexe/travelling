import 'package:flutter/material.dart';

import 'expense_models.dart';

extension ExpenseCategoryIcon on ExpenseCategory {
  IconData get icon => switch (id) {
        'food' => Icons.restaurant_outlined,
        'transport' => Icons.directions_car_outlined,
        'stay' => Icons.hotel_outlined,
        'tickets' => Icons.confirmation_number_outlined,
        'shopping' => Icons.shopping_bag_outlined,
        'fuel' => Icons.local_gas_station_outlined,
        'activities' => Icons.attractions_outlined,
        'medical' => Icons.medical_services_outlined,
        'emergency' => Icons.emergency_outlined,
        _ => Icons.category_outlined,
      };
}
