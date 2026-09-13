/// A single fuel fill-up, persisted on-device for offline-first use.
class FuelEntry {
  const FuelEntry({
    required this.id,
    required this.date,
    required this.odometerKm,
    required this.liters,
    required this.cost,
    this.notes,
    this.parkingNote,
  });

  final String id;
  final DateTime date;

  /// Odometer reading at the time of this fill-up (km).
  final double odometerKm;

  /// Fuel added (litres).
  final double liters;

  /// Total amount paid (₹).
  final double cost;
  final String? notes;

  /// Optional parking note attached to this stop.
  final String? parkingNote;

  double get pricePerLiter => liters > 0 ? cost / liters : 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'date': date.toIso8601String(),
        'odometerKm': odometerKm,
        'liters': liters,
        'cost': cost,
        'notes': notes,
        'parkingNote': parkingNote,
      };

  factory FuelEntry.fromJson(Map<String, dynamic> json) => FuelEntry(
        id: json['id'] as String? ?? '',
        date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
        odometerKm: (json['odometerKm'] as num?)?.toDouble() ?? 0,
        liters: (json['liters'] as num?)?.toDouble() ?? 0,
        cost: (json['cost'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String?,
        parkingNote: json['parkingNote'] as String?,
      );
}
