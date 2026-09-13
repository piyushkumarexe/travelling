import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/fuel_log.dart';

/// Device-local fuel log + service reminders + parking notes.
///
/// Stored in SharedPreferences keyed per user id, so the vehicle tab works
/// fully offline with no backend dependency.
class FuelLogStore extends ChangeNotifier {
  FuelLogStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _prefix = 'fuel.entries.v1.';
  static const String _servicePrefix = 'fuel.service.v1.';

  SharedPreferences? _prefs;
  String? _uid;
  List<FuelEntry> _entries = const <FuelEntry>[];
  bool _loaded = false;

  // Service reminder: odometer reading (km) when service is next due.
  double _nextServiceOdometerKm = 0;
  String _serviceNote = '';

  List<FuelEntry> get entries => _entries;
  bool get loaded => _loaded;
  double get nextServiceOdometerKm => _nextServiceOdometerKm;
  String get serviceNote => _serviceNote;

  /// Entries sorted by odometer, ascending.
  List<FuelEntry> get orderedEntries {
    final List<FuelEntry> list = List<FuelEntry>.from(_entries)
      ..sort((FuelEntry a, FuelEntry b) =>
          a.odometerKm.compareTo(b.odometerKm));
    return list;
  }

  double get totalCost =>
      _entries.fold<double>(0, (double sum, FuelEntry e) => sum + e.cost);

  /// Average mileage (km per litre) computed from consecutive fill-ups:
  /// distance travelled since the previous fill-up ÷ fuel added now.
  /// Returns null when fewer than two fill-ups are logged.
  double? get averageMileage {
    final List<FuelEntry> list = orderedEntries;
    double kmSum = 0;
    double lSum = 0;
    int pairs = 0;
    for (int i = 1; i < list.length; i++) {
      final double km = list[i].odometerKm - list[i - 1].odometerKm;
      if (km <= 0 || list[i].liters <= 0) continue;
      kmSum += km;
      lSum += list[i].liters;
      pairs++;
    }
    if (pairs == 0 || lSum <= 0) return null;
    return kmSum / lSum;
  }

  /// Estimated fuel cost for a trip of [distanceKm] using the latest
  /// recorded price per litre and average mileage. Returns null when there
  /// is no logged data to estimate from (never invents numbers).
  double? estimateTripFuel(double distanceKm) {
    final double? mileage = averageMileage;
    final double price = _latestPricePerLiter();
    if (mileage == null || mileage <= 0 || price <= 0) return null;
    return (distanceKm / mileage) * price;
  }

  double _latestPricePerLiter() {
    final List<FuelEntry> list = orderedEntries;
    if (list.isEmpty) return 0;
    return list.last.pricePerLiter;
  }

  String _key() => '$_prefix${_uid ?? 'anon'}';
  String _serviceKey() => '$_servicePrefix${_uid ?? 'anon'}';

  Future<void> loadFor(String uid) async {
    _prefs ??= await SharedPreferences.getInstance();
    _uid = uid;
    final String? raw = _prefs!.getString(_key());
    if (raw == null || raw.isEmpty) {
      _entries = const <FuelEntry>[];
    } else {
      try {
        final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
        _entries = decoded
            .map((dynamic e) => FuelEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _entries = const <FuelEntry>[];
      }
    }
    final String? svc = _prefs!.getString(_serviceKey());
    if (svc != null && svc.isNotEmpty) {
      final List<String> parts = svc.split('|');
      _nextServiceOdometerKm = double.tryParse(parts.first) ?? 0;
      _serviceNote = parts.length > 1 ? parts[1] : '';
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> add(FuelEntry entry) async {
    _entries = <FuelEntry>[..._entries, entry];
    await _save();
  }

  Future<void> update(FuelEntry entry) async {
    _entries = <FuelEntry>[
      for (final FuelEntry e in _entries)
        if (e.id == entry.id) entry else e,
    ];
    await _save();
  }

  Future<void> remove(String id) async {
    _entries = _entries.where((FuelEntry e) => e.id != id).toList();
    await _save();
  }

  Future<void> setServiceReminder(double odometerKm, String note) async {
    _nextServiceOdometerKm = odometerKm;
    _serviceNote = note;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_serviceKey(), '$odometerKm|$note');
    notifyListeners();
  }

  Future<void> clearServiceReminder() async {
    _nextServiceOdometerKm = 0;
    _serviceNote = '';
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_serviceKey());
    notifyListeners();
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
      _key(),
      jsonEncode(_entries.map((FuelEntry e) => e.toJson()).toList()),
    );
    notifyListeners();
  }
}
