import 'dart:convert';

import 'package:flutter/foundation.dart';

/// TRAVEL EXPENSE GUARD — data model.
///
/// Storage layout (existing Firebase architecture, per-user nested pattern
/// like /users/{uid}/itineraries):
///   Firestore : users/{uid}/expenses/{id}          (client-generated id →
///                                                   idempotent offline sync)
///   Firestore : users/{uid}/expenseData/budget     (optional budgets)
///   Storage   : receipts/{uid}/{expenseId}_.jpg    (only the download URL is
///                                                   saved in Firestore —
///                                                   never the image binary)

class ExpenseCategory {
  final String id;
  final String label;
  final String emoji;
  const ExpenseCategory(this.id, this.label, this.emoji);

  static const List<ExpenseCategory> all = <ExpenseCategory>[
    ExpenseCategory('food', 'Food', '🍽️'),
    ExpenseCategory('transport', 'Transport', '🚕'),
    ExpenseCategory('stay', 'Hotel/Stay', '🏨'),
    ExpenseCategory('tickets', 'Tickets', '🎫'),
    ExpenseCategory('shopping', 'Shopping', '🛍️'),
    ExpenseCategory('fuel', 'Fuel', '⛽'),
    ExpenseCategory('activities', 'Activities', '🎢'),
    ExpenseCategory('medical', 'Medical', '💊'),
    ExpenseCategory('emergency', 'Emergency', '🚨'),
    ExpenseCategory('other', 'Other', '📦'),
  ];

  static ExpenseCategory of(String id) => all.firstWhere(
        (ExpenseCategory c) => c.id == id,
        orElse: () => ExpenseCategory.other,
      );

  static bool exists(String id) => all.any((ExpenseCategory c) => c.id == id);
}

/// Currencies the traveler can pick (no conversion service exists in the
/// project, so totals are NEVER merged across currencies).
class Currencies {
  static const List<String> common = <String>[
    'INR', 'USD', 'EUR', 'GBP', 'AED', 'JPY', 'SGD', 'THB', 'NPR', 'LKR',
  ];

  static bool isSupported(String code) =>
      common.contains(code.toUpperCase());
}

/// One participant's share of a SPLIT expense (saved inside the expense
/// document — never as fake standalone expenses).
class SplitParticipant {
  const SplitParticipant({
    required this.name,
    required this.amount,
    this.isSelf = false,
  });

  final String name;
  final double amount;
  final bool isSelf;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'amount': amount,
        'isSelf': isSelf,
      };

  static SplitParticipant fromJson(Map<String, dynamic> m) => SplitParticipant(
        name: (m['name'] as String?) ?? '',
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        isSelf: (m['isSelf'] as bool?) ?? false,
      );
}

/// Sync state shown honestly in the UI.
enum ExpenseSync { synced, local, syncing }

class Expense {
  const Expense({
    required this.id,
    required this.userId,
    required this.amount,
    required this.currency,
    required this.category,
    required this.merchant,
    required this.expenseDate,
    required this.createdAt,
    required this.updatedAt,
    this.tripId,
    this.paymentMethod,
    this.notes,
    this.receiptUrl,
    this.latitude,
    this.longitude,
    this.locationName,
    this.splits = const <SplitParticipant>[],
    this.sync = ExpenseSync.synced,
    this.pendingDelete = false,
  });

  final String id;
  final String userId;
  final double amount;
  final String currency;
  final String category; // ExpenseCategory id
  final String merchant; // description / merchant
  final DateTime expenseDate;
  final DateTime createdAt;
  final DateTime updatedAt;

  final String? tripId; // link to the existing local TripPlan id
  final String? paymentMethod; // cash | upi | card | other
  final String? notes;
  final String? receiptUrl; // Storage download URL (binary never in Firestore)
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final List<SplitParticipant> splits;
  final ExpenseSync sync;
  final bool pendingDelete;

  static const List<String> paymentMethods = <String>['cash', 'upi', 'card'];

  Expense copyWith({
    double? amount,
    String? currency,
    String? category,
    String? merchant,
    DateTime? expenseDate,
    String? tripId,
    bool clearTrip = false,
    String? paymentMethod,
    bool clearPayment = false,
    String? notes,
    bool clearNotes = false,
    String? receiptUrl,
    double? latitude,
    double? longitude,
    String? locationName,
    List<SplitParticipant>? splits,
    ExpenseSync? sync,
    bool? pendingDelete,
    DateTime? updatedAt,
  }) {
    return Expense(
      id: id,
      userId: userId,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      category: category ?? this.category,
      merchant: merchant ?? this.merchant,
      expenseDate: expenseDate ?? this.expenseDate,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tripId: clearTrip ? null : (tripId ?? this.tripId),
      paymentMethod:
          clearPayment ? null : (paymentMethod ?? this.paymentMethod),
      notes: clearNotes ? null : (notes ?? this.notes),
      receiptUrl: receiptUrl ?? this.receiptUrl,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      splits: splits ?? this.splits,
      sync: sync ?? this.sync,
      pendingDelete: pendingDelete ?? this.pendingDelete,
    );
  }

  Map<String, dynamic> toFirestore() => <String, dynamic>{
        'id': id,
        'userId': userId,
        'tripId': tripId,
        'amount': amount,
        'currency': currency,
        'category': category,
        'merchant': merchant,
        'expenseDate': expenseDate.millisecondsSinceEpoch,
        'paymentMethod': paymentMethod,
        'notes': notes,
        'receiptUrl': receiptUrl,
        'latitude': latitude,
        'longitude': longitude,
        'locationName': locationName,
        'splits': splits.map((SplitParticipant s) => s.toJson()).toList(),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static Expense fromFirestore(Map<String, dynamic> m,
      {ExpenseSync sync = ExpenseSync.synced}) {
    return Expense(
      id: (m['id'] as String?) ?? '',
      userId: (m['userId'] as String?) ?? '',
      amount: (m['amount'] as num?)?.toDouble() ?? 0,
      currency: (m['currency'] as String?) ?? 'INR',
      category: (m['category'] as String?) ?? 'other',
      merchant: (m['merchant'] as String?) ?? '',
      expenseDate: DateTime.fromMillisecondsSinceEpoch(
          ((m['expenseDate'] as num?) ?? 0).toInt()),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          ((m['createdAt'] as num?) ?? 0).toInt()),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
          ((m['updatedAt'] as num?) ?? 0).toInt()),
      tripId: m['tripId'] as String?,
      paymentMethod: m['paymentMethod'] as String?,
      notes: m['notes'] as String?,
      receiptUrl: m['receiptUrl'] as String?,
      latitude: (m['latitude'] as num?)?.toDouble(),
      longitude: (m['longitude'] as num?)?.toDouble(),
      locationName: m['locationName'] as String?,
      splits: ((m['splits'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((Map s) =>
              SplitParticipant.fromJson(s.cast<String, dynamic>()))
          .toList(),
      sync: sync,
    );
  }

  /// Local cache/queue encoding (adds sync + pendingDelete).
  Map<String, dynamic> toLocal() =>
      <String, dynamic>{...toFirestore(), 'sync': sync.name,
        'pendingDelete': pendingDelete};

  static Expense fromLocal(Map<String, dynamic> m) {
    final Expense e = Expense.fromFirestore(m);
    return Expense(
      id: e.id,
      userId: e.userId,
      amount: e.amount,
      currency: e.currency,
      category: e.category,
      merchant: e.merchant,
      expenseDate: e.expenseDate,
      createdAt: e.createdAt,
      updatedAt: e.updatedAt,
      tripId: e.tripId,
      paymentMethod: e.paymentMethod,
      notes: e.notes,
      receiptUrl: e.receiptUrl,
      latitude: e.latitude,
      longitude: e.longitude,
      locationName: e.locationName,
      splits: e.splits,
      sync: ExpenseSync.values
          .where((ExpenseSync s) => s.name == m['sync'])
          .firstOrNull ?? ExpenseSync.synced,
      pendingDelete: (m['pendingDelete'] as bool?) ?? false,
    );
  }

  String encode() => jsonEncode(toLocal());

  static Expense decode(String raw) =>
      Expense.fromLocal((jsonDecode(raw) as Map).cast<String, dynamic>());
}

/// Optional budget configuration (trip-level and/or daily).
class BudgetConfig {
  const BudgetConfig({
    this.daily,
    this.perTrip = const <String, double>{},
    this.currency = 'INR',
  });

  final double? daily; // per-day budget in [currency]
  final Map<String, double> perTrip; // tripId -> budget
  final String currency;

  BudgetConfig copyWith({double? daily, Map<String, double>? perTrip}) =>
      BudgetConfig(
        daily: daily ?? this.daily,
        perTrip: perTrip ?? this.perTrip,
        currency: currency,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'daily': daily,
        'perTrip': perTrip,
        'currency': currency,
      };

  static BudgetConfig fromJson(Map<String, dynamic> m) => BudgetConfig(
        daily: (m['daily'] as num?)?.toDouble(),
        perTrip: ((m['perTrip'] as Map?) ?? const <String, dynamic>{})
            .map((Object? k, Object? v) =>
                MapEntry(k.toString(), (v as num?)?.toDouble() ?? 0)),
        currency: (m['currency'] as String?) ?? 'INR',
      );
}
