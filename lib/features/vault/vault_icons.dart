import 'package:flutter/material.dart';

import 'travel_document.dart';

extension TravelDocTypeIcon on TravelDocType {
  IconData get icon => switch (this) {
        TravelDocType.passport => Icons.menu_book_outlined,
        TravelDocType.visa => Icons.approval_outlined,
        TravelDocType.idProof => Icons.badge_outlined,
        TravelDocType.flightTicket => Icons.flight_outlined,
        TravelDocType.trainTicket => Icons.train_outlined,
        TravelDocType.busTicket => Icons.directions_bus_outlined,
        TravelDocType.hotelBooking => Icons.hotel_outlined,
        TravelDocType.cabRental => Icons.car_rental_outlined,
        TravelDocType.activityTicket => Icons.local_activity_outlined,
        TravelDocType.travelInsurance => Icons.health_and_safety_outlined,
        TravelDocType.other => Icons.description_outlined,
      };
}
