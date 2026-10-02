import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/location_service.dart';
import '../../core/services/storage_service.dart';
import '../../data/local/trip_plan_store.dart';
import 'expense_models.dart';

/// TRAVEL EXPENSE GUARD — repository.
///
/// - Firestore: users/{uid}/expenses/{id} (owner-only rules) + a budget doc.
/// - Storage: receipts/{uid}/{expenseId}*.jpg — Firestore keeps only the URL.
/// - Offline-first: every write goes to the local cache + op queue FIRST
///   (stable client-generated ids → idempotent replay), then syncs to
///   Firestore when the network allows. States are honest: local / syncing /
///   synced — a Firestore write is NEVER reported as done when it failed.
/// - Dashboard reads the local cache instantly, then refreshes from
///   Firestore (single listener, bounded to the most recent page).
class ExpenseRepository extends ChangeNotifier {
  ExpenseRepository({required this.tripStore, required this.storage});

  final TripPlanStore tripStore;
  final StorageService storage;

  static const int _recentLimit = 200;

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseStorage get _storage => FirebaseStorage.instance;

  String? _uid;
  List<Expense> _expenses = <Expense>[];
  BudgetConfig _budget = const BudgetConfig();
  int _pendingOps = 0;
  bool _syncing = false;
  String? _lastError;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  bool _loadedForUser = false;

  List<Expense> get expenses =>
      _expenses.where((Expense e) => !e.pendingDelete).toList();
  BudgetConfig get budget => _budget;
  int get pendingOps => _pendingOps;
  bool get syncing => _syncing;
  String? get lastError => _lastError;
  bool get ready => _uid != null && _loadedForUser;

  /// ---------- lifecycle ----------

  Future<void> start(String uid) async {
    if (_uid == uid) return;
    await _sub?.cancel();
    _uid = uid;
    _loadedForUser = false;
    await _loadCache();
    await _loadBudget();
    await _sync(); // replay queued ops first
    _watchRemote();
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _uid = null;
    _expenses = const <Expense>[];
    _loadedForUser = false;
  }

  String get _cacheKey => 'expense.cache.v1.$_uid';
  String get _queueKey => 'expense.queue.v1.$_uid';
  String get _budgetKey => 'expense.budget.v1.$_uid';

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('users').doc(_uid!).collection('expenses');

  DocumentReference<Map<String, dynamic>> get _budgetDoc =>
      _db.collection('users').doc(_uid!).collection('expenseData').doc('budget');

  /// ---------- local cache + queue ----------

  Future<void> _loadCache() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_cacheKey);
      if (raw != null) {
        final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
        _expenses = list
            .whereType<Map>()
            .map((Map m) =>
                Expense.fromLocal(m.cast<String, dynamic>()))
            .toList();
      }
      final String? q = prefs.getString(_queueKey);
      _pendingOps = q == null ? 0 : (jsonDecode(q) as List).length;
    } catch (_) {
      // Corrupt cache → start empty; Firestore refresh will repopulate.
    }
  }

  Future<void> _saveCache() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _cacheKey,
        jsonEncode(_expenses.map((Expense e) => e.toLocal()).toList()));
  }

  Future<List<Map<String, dynamic>>> _readQueue() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? q = prefs.getString(_queueKey);
    if (q == null) return <Map<String, dynamic>>[];
    return (jsonDecode(q) as List)
        .whereType<Map>()
        .map((Map e) => e.cast<String, dynamic>())
        .toList();
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> ops) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, jsonEncode(ops));
    _pendingOps = ops.length;
    notifyListeners();
  }

  /// ---------- public writes (offline-first, idempotent) ----------

  String newId() => 'exp-${DateTime.now().millisecondsSinceEpoch}'
      '-${(DateTime.now().microsecondsSinceEpoch % 100000)}';

  /// Amount + category is enough; everything else optional.
  Future<void> addExpense(Expense e, {XFile? receipt}) async {
    _expenses = <Expense>[..._expenses, e];
    await _saveCache();
    notifyListeners();
    await _enqueue(<String, dynamic>{
      'key': newId(),
      'op': 'upsert',
      'id': e.id,
      'data': e.toFirestore(),
    });
    if (receipt != null) {
      await _uploadReceipt(e.id, receipt);
    }
    unawaited(_sync());
  }

  Future<void> updateExpense(Expense e) async {
    _expenses = _expenses
        .map((Expense x) => x.id == e.id
            ? e.copyWith(sync: ExpenseSync.local)
            : x)
        .toList();
    await _saveCache();
    notifyListeners();
    await _enqueue(<String, dynamic>{
      'key': newId(),
      'op': 'upsert',
      'id': e.id,
      'data': e.toFirestore(),
    });
    unawaited(_sync());
  }

  /// Deletes the Firestore record + best-effort receipt cleanup so no broken
  /// receipt reference is left behind.
  Future<void> deleteExpense(String id) async {
    final Expense? target =
        _expenses.where((Expense x) => x.id == id).firstOrNull;
    _expenses = _expenses.where((Expense x) => x.id != id).toList();
    await _saveCache();
    notifyListeners();
    await _enqueue(<String, dynamic>{'key': newId(), 'op': 'delete', 'id': id});
    if (target?.receiptUrl != null) {
      unawaited(_deleteReceipt(target!.receiptUrl!));
    }
    unawaited(_sync());
  }

  /// Receipt attach AFTER save (retry path): uploads and links the URL.
  Future<void> attachReceipt(String expenseId, XFile receipt) async {
    await _uploadReceipt(expenseId, receipt);
  }

  Future<void> _uploadReceipt(String expenseId, XFile file) async {
    // Reuses the app's StorageService (validation + rules path
    // receipts/{uid}/{expenseId}.jpg). image_picker already resized the
    // photo at pick time, keeping text readable while small.
    final String url = await storage.uploadReceipt(file, _uid!, expenseId);
    final Expense? e =
        _expenses.where((Expense x) => x.id == expenseId).firstOrNull;
    if (e != null) {
      await updateExpense(e.copyWith(receiptUrl: url));
    }
  }

  Future<void> _deleteReceipt(String url) async {
    try {
      await _storage.refFromURL(url).delete();
    } catch (_) {
      // Best-effort: an already-missing file must not block the delete.
    }
  }

  /// ---------- budget ----------

  Future<void> _loadBudget() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_budgetKey);
      if (raw != null) {
        _budget = BudgetConfig.fromJson(
            (jsonDecode(raw) as Map).cast<String, dynamic>());
      }
    } catch (_) {}
  }

  Future<void> _saveBudgetLocal() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_budgetKey, jsonEncode(_budget.toJson()));
  }

  Future<void> saveBudget(BudgetConfig b) async {
    _budget = b;
    await _saveBudgetLocal();
    notifyListeners();
    try {
      await _budgetDoc.set(<String, dynamic>{
        ...b.toJson(),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    } catch (_) {
      // Budget stays local (it is functional offline); retried with next sync.
      await _enqueue(<String, dynamic>{
        'key': newId(),
        'op': 'budget',
        'data': b.toJson(),
      });
    }
  }

  /// ---------- sync ----------

  Future<void> _enqueue(Map<String, dynamic> op) async {
    final List<Map<String, dynamic>> ops = await _readQueue();
    // Idempotency: an op for the same id replaces the older pending one.
    ops.removeWhere((Map<String, dynamic> e) =>
        e['id'] == op['id'] && (op['op'] == 'upsert' || op['op'] == 'delete'));
    ops.add(op);
    await _writeQueue(ops);
  }

  /// Replays the queue; safe to call any time. Returns true when the queue
  /// is empty afterwards. NEVER marks anything synced on failure.
  Future<bool> _sync() async {
    if (_uid == null || _syncing) return _pendingOps == 0;
    _syncing = true;
    _lastError = null;
    notifyListeners();
    try {
      final List<Map<String, dynamic>> ops = await _readQueue();
      for (final Map<String, dynamic> op in ops) {
        try {
          switch (op['op'] as String) {
            case 'upsert':
              await _col
                  .doc(op['id'] as String)
                  .set((op['data'] as Map).cast<String, dynamic>());
              _markSynced(op['id'] as String);
              break;
            case 'delete':
              await _col.doc(op['id'] as String).delete();
              break;
            case 'budget':
              await _budgetDoc.set(<String, dynamic>{
                ...(op['data'] as Map).cast<String, dynamic>(),
                'updatedAt': DateTime.now().millisecondsSinceEpoch,
              }, SetOptions(merge: true));
              break;
          }
        } on FirebaseException catch (e) {
          _lastError = 'Sync pending: ${e.code}';
          break; // keep remaining ops queued — never fake success
        } on SocketException {
          _lastError = 'No network — changes saved locally.';
          break;
        }
        final List<Map<String, dynamic>> fresh = await _readQueue();
        final String key = op['key'] as String? ?? '';
        await _writeQueue(fresh
            .where((Map<String, dynamic> e) => e['key'] != key)
            .toList());
      }
      return _pendingOps == 0;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> syncNow() async {
    await _sync();
    notifyListeners();
  }

  void _markSynced(String id) {
    final Expense? e = _expenses.where((Expense x) => x.id == id).firstOrNull;
    if (e != null && e.sync != ExpenseSync.synced) {
      _expenses = _expenses
          .map((Expense x) => x.id == id
              ? x.copyWith(sync: ExpenseSync.synced)
              : x)
          .toList();
    }
  }

  /// ---------- remote watch (single bounded listener) ----------

  void _watchRemote() {
    _sub?.cancel();
    _sub = _col
        .orderBy('expenseDate', descending: true)
        .limit(_recentLimit)
        .snapshots()
        .listen((QuerySnapshot<Map<String, dynamic>> snap) {
      final List<Expense> remote = snap.docs
          .map((QueryDocumentSnapshot<Map<String, dynamic>> d) =>
              Expense.fromFirestore(d.data()))
          .toList();
      // Merge: local pending edits win until they sync.
      final Map<String, Expense> byId = <String, Expense>{
        for (final Expense e in remote) e.id: e,
      };
      for (final Expense e in _expenses) {
        if (e.sync != ExpenseSync.synced || e.pendingDelete) {
          byId[e.id] = e;
        }
      }
      _expenses = byId.values.toList()
        ..sort((Expense a, Expense b) =>
            b.expenseDate.compareTo(a.expenseDate));
      _loadedForUser = true;
      unawaited(_saveCache());
      notifyListeners();
    }, onError: (Object e) {
      _lastError = 'Live refresh unavailable — showing saved data.';
      _loadedForUser = true;
      notifyListeners();
    });
  }

  /// ---------- optional location (never blocks creation) ----------

  /// Attaches the current fix + resolved name ONLY when permission was
  /// already granted. Never requests permission here.
  Future<({double? lat, double? lng, String? name})?> currentPlace(
      LocationService location) async {
    try {
      final LocationPermission p = await Geolocator.checkPermission();
      if (p != LocationPermission.whileInUse &&
          p != LocationPermission.always) {
        return null;
      }
      final Position? pos = await location.currentPosition();
      if (pos == null) return null;
      return (lat: pos.latitude, lng: pos.longitude, name: null);
    } catch (_) {
      return null;
    }
  }
}
