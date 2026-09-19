/// A single budget/expense entry for a trip, persisted locally.
///
/// Entries are stored device-locally so the wallet works fully offline.
/// Nothing here is sent to any server.
class WalletEntry {
  const WalletEntry({
    required this.id,
    required this.title,
    required this.category,
    required this.amount,
    required this.date,
    this.notes,
  });

  final String id;
  final String title;
  final String category;
  final double amount;
  final DateTime date;
  final String? notes;

  static const List<String> categories = <String>[
    'Hotel',
    'Food',
    'Fuel',
    'Tickets',
    'Shopping',
    'Transport',
    'Other',
  ];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'category': category,
        'amount': amount,
        'date': date.toIso8601String(),
        'notes': notes,
      };

  factory WalletEntry.fromJson(Map<String, dynamic> json) => WalletEntry(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        category: json['category'] as String? ?? 'Other',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        date: DateTime.tryParse(json['date'] as String? ?? '') ??
            DateTime.now(),
        notes: json['notes'] as String?,
      );
}

/// Immutable wallet snapshot used for rendering the budget dashboard.
class WalletSummary {
  const WalletSummary({
    required this.entries,
    required this.totalSpent,
    required this.perCategory,
  });

  final List<WalletEntry> entries;
  final double totalSpent;

  /// Category label → sum of amounts, sorted by spend descending.
  final Map<String, double> perCategory;
}
