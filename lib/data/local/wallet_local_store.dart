import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/wallet_entry.dart';

/// Device-local wallet persistence.
///
/// Budget and expense entries are stored in SharedPreferences keyed per user
/// id, so the wallet works entirely offline and never depends on a backend.
class WalletLocalStore extends ChangeNotifier {
  WalletLocalStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _prefix = 'wallet.entries.v1.';
  static const String _budgetPrefix = 'wallet.budget.v1.';

  SharedPreferences? _prefs;
  String? _uid;
  List<WalletEntry> _entries = const <WalletEntry>[];
  double _budget = 0;
  bool _loaded = false;

  List<WalletEntry> get entries => _entries;
  double get budget => _budget;
  bool get loaded => _loaded;

  double get totalSpent =>
      _entries.fold<double>(0, (double sum, WalletEntry e) => sum + e.amount);

  double get remaining => _budget <= 0 ? 0 : (_budget - totalSpent);

  /// Average spend per day of the current trip, when a trip start date is
  /// known. Callers pass [days] (length of the trip) when available.
  double dailyAverage(int days) =>
      days <= 0 ? totalSpent : totalSpent / days;

  Map<String, double> get perCategory {
    final Map<String, double> map = <String, double>{};
    for (final WalletEntry e in _entries) {
      map[e.category] = (map[e.category] ?? 0) + e.amount;
    }
    final List<MapEntry<String, double>> sorted =
        map.entries.toList()
          ..sort((MapEntry<String, double> a, MapEntry<String, double> b) =>
              b.value.compareTo(a.value));
    return <String, double>{for (final MapEntry<String, double> e in sorted) e.key: e.value};
  }

  String _key() => '$_prefix${_uid ?? 'anon'}';
  String _budgetKey() => '$_budgetPrefix${_uid ?? 'anon'}';

  /// Bind the store to a user id and load their entries.
  Future<void> loadFor(String uid) async {
    _prefs ??= await SharedPreferences.getInstance();
    _uid = uid;
    final String? raw = _prefs!.getString(_key());
    if (raw == null || raw.isEmpty) {
      _entries = const <WalletEntry>[];
    } else {
      try {
        final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
        _entries = decoded
            .map((dynamic e) =>
                WalletEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _entries = const <WalletEntry>[];
      }
    }
    _budget = _prefs!.getDouble(_budgetKey()) ?? 0;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setBudget(double value) async {
    _budget = value;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setDouble(_budgetKey(), value);
    notifyListeners();
  }

  Future<void> add(WalletEntry entry) async {
    _entries = <WalletEntry>[..._entries, entry];
    await _save();
  }

  Future<void> update(WalletEntry entry) async {
    _entries = <WalletEntry>[
      for (final WalletEntry e in _entries)
        if (e.id == entry.id) entry else e,
    ];
    await _save();
  }

  Future<void> remove(String id) async {
    _entries = _entries.where((WalletEntry e) => e.id != id).toList();
    await _save();
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
      _key(),
      jsonEncode(_entries.map((WalletEntry e) => e.toJson()).toList()),
    );
    notifyListeners();
  }
}
