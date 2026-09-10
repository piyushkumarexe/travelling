import 'package:cloud_firestore/cloud_firestore.dart';

/// An AI-generated, saved travel itinerary.
library;

class ItineraryItem {
  ItineraryItem({
    required this.time,
    required this.title,
    this.description = '',
    this.cost = '',
  });

  final String time;
  final String title;
  final String description;
  final String cost;

  factory ItineraryItem.fromMap(Map<String, dynamic> m) => ItineraryItem(
        time: (m['time'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        description: (m['description'] as String?) ?? '',
        cost: (m['cost'] as String?) ?? '',
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'time': time,
        'title': title,
        'description': description,
        'cost': cost,
      };
}

class ItineraryDay {
  ItineraryDay({required this.day, required this.title, required this.items});

  final int day;
  final String title;
  final List<ItineraryItem> items;

  factory ItineraryDay.fromMap(Map<String, dynamic> m) {
    final List<dynamic> raw = (m['items'] is List) ? m['items'] as List : <dynamic>[];
    return ItineraryDay(
      day: (m['day'] as num?)?.toInt() ?? 0,
      title: (m['title'] as String?) ?? 'Day',
      items: raw
          .whereType<Map<String, dynamic>>()
          .map(ItineraryItem.fromMap)
          .toList(),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'day': day,
        'title': title,
        'items': items.map((ItineraryItem i) => i.toMap()).toList(),
      };
}

class Itinerary {
  Itinerary({
    required this.id,
    required this.uid,
    required this.destination,
    required this.days,
    required this.interests,
    required this.budget,
    required this.travelStyle,
    required this.plan,
    required this.createdAt,
  });

  final String id;
  final String uid;
  final String destination;
  final int days;
  final List<String> interests;
  final String budget;
  final String travelStyle;
  final List<ItineraryDay> plan;
  final DateTime createdAt;

  factory Itinerary.fromMap(String id, Map<String, dynamic> m) {
    final List<dynamic> rawPlan =
        (m['plan'] is List) ? m['plan'] as List : <dynamic>[];
    return Itinerary(
      id: id,
      uid: (m['uid'] as String?) ?? '',
      destination: (m['destination'] as String?) ?? 'Trip',
      days: (m['days'] as num?)?.toInt() ?? 1,
      interests: (m['interests'] is List)
          ? (m['interests'] as List).whereType<String>().toList()
          : <String>[],
      budget: (m['budget'] as String?) ?? 'mid',
      travelStyle: (m['travelStyle'] as String?) ?? 'balanced',
      plan: rawPlan
          .whereType<Map<String, dynamic>>()
          .map(ItineraryDay.fromMap)
          .toList(),
      createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'uid': uid,
        'destination': destination,
        'days': days,
        'interests': interests,
        'budget': budget,
        'travelStyle': travelStyle,
        'plan': plan.map((ItineraryDay d) => d.toMap()).toList(),
        'createdAt': createdAt.toUtc(),
        'updatedAt': DateTime.now().toUtc(),
      };
}
