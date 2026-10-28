import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/places.dart';

/// UID-scoped saved places with an offline outbox and Firestore sync.
class FavoritesStore {
  FavoritesStore._();

  static const String _localPrefix = 'favorite_places.v2.';
  static const String _pendingPrefix = 'favorite_places.pending.v2.';
  static Future<void> _toggleQueue = Future<void>.value();

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  static String _documentId(String placeId) {
    final String encoded = base64Url.encode(utf8.encode(placeId));
    return encoded.replaceAll('=', '');
  }

  static String _canonicalId(Place place) => place.placeId.trim().isNotEmpty
      ? place.placeId.trim()
      : '${place.name.trim()}|${place.lat.toStringAsFixed(6)}|'
          '${place.lng.toStringAsFixed(6)}';

  static Place _withCanonicalId(Place place) {
    if (place.placeId.trim().isNotEmpty) return place;
    final Map<String, dynamic> json = place.toJson();
    json['placeId'] = _canonicalId(place);
    return Place.fromJson(json);
  }

  static CollectionReference<Map<String, dynamic>> _collection(String uid) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('savedPlaces');

  static Future<List<Place>> _readLocal(String uid) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('$_localPrefix$uid');
      if (raw == null) return <Place>[];
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return <Place>[];
      return decoded
          .whereType<Map>()
          .map((entry) => Place.fromJson(Map<String, dynamic>.from(entry)))
          .toList();
    } catch (_) {
      return <Place>[];
    }
  }

  static Future<void> _writeLocal(String uid, List<Place> places) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_localPrefix$uid',
      jsonEncode(places.map((place) => place.toJson()).toList()),
    );
  }

  static Future<Map<String, bool>> _readPending(String uid) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('$_pendingPrefix$uid');
      if (raw == null) return <String, bool>{};
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, bool>{};
      return decoded.map((key, value) =>
          MapEntry(key.toString(), value == true));
    } catch (_) {
      return <String, bool>{};
    }
  }

  static Future<void> _writePending(
    String uid,
    Map<String, bool> pending,
  ) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_pendingPrefix$uid', jsonEncode(pending));
  }

  static Future<void> _syncPending(String uid) async {
    final Map<String, bool> pending = await _readPending(uid);
    if (pending.isEmpty) return;
    final List<Place> local = await _readLocal(uid);
    for (final MapEntry<String, bool> entry
        in List<MapEntry<String, bool>>.of(pending.entries)) {
      try {
        final DocumentReference<Map<String, dynamic>> ref =
            _collection(uid).doc(entry.key);
        if (!entry.value) {
          await ref.delete();
        } else {
          final Place place = local.firstWhere(
            (item) => _documentId(_canonicalId(item)) == entry.key,
            orElse: () => throw StateError('Missing local saved place'),
          );
          await ref.set(<String, dynamic>{
            'uid': uid,
            'placeId': _canonicalId(place),
            'place': place.toJson(),
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        pending.remove(entry.key);
        await _writePending(uid, pending);
      } catch (_) {
        // Keep this and subsequent operations queued for the next sync.
        return;
      }
    }
  }

  static Future<List<Place>> _all() async {
    final String? uid = _uid;
    if (uid == null || uid.isEmpty) return <Place>[];
    await _syncPending(uid);
    final List<Place> local = await _readLocal(uid);
    final Map<String, bool> pending = await _readPending(uid);
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot =
          await _collection(uid).get();
      final List<Place> remote = snapshot.docs.map((document) {
        final Object? raw = document.data()['place'];
        if (raw is! Map) return null;
        return Place.fromJson(Map<String, dynamic>.from(raw));
      }).whereType<Place>().toList();
      final Map<String, Place> merged = <String, Place>{
        for (final Place place in remote) _documentId(_canonicalId(place)): place,
      };
      for (final Place place in local) {
        final String id = _documentId(_canonicalId(place));
        if (pending[id] == true) merged[id] = place;
      }
      for (final MapEntry<String, bool> entry in pending.entries) {
        if (!entry.value) merged.remove(entry.key);
      }
      final List<Place> result = merged.values.toList();
      await _writeLocal(uid, result);
      return result;
    } catch (_) {
      return local;
    }
  }

  static Future<List<Place>> all() => _all();

  static Future<Set<String>> ids() async {
    final List<Place> items = await _all();
    return items.map(_canonicalId).toSet();
  }

  static Future<bool> contains(String placeId) async {
    final Set<String> saved = await ids();
    return saved.contains(placeId);
  }

  static Future<bool> containsPlace(Place place) async =>
      contains(_canonicalId(place));

  static Future<bool> toggle(Place place) {
    final Completer<bool> completer = Completer<bool>();
    _toggleQueue = _toggleQueue.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await _toggle(_withCanonicalId(place)));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static Future<bool> _toggle(Place place) async {
    final String? uid = _uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('Sign in to save places to your account.');
    }
    final String id = _documentId(_canonicalId(place));
    final List<Place> items = await _all();
    final int index = items.indexWhere(
      (item) => _documentId(_canonicalId(item)) == id,
    );
    final bool saved = index < 0;
    if (saved) {
      items.insert(0, place);
    } else {
      items.removeAt(index);
    }
    await _writeLocal(uid, items);
    final Map<String, bool> pending = await _readPending(uid);
    pending[id] = saved;
    await _writePending(uid, pending);
    await _syncPending(uid);
    return saved;
  }
}
