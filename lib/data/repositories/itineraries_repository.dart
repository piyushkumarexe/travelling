import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/itinerary.dart';

/// Itineraries are stored in the per-user subcollection
/// users/{uid}/itineraries so security rules can enforce ownership
/// without any query-introspection (which rules cannot do).
class ItinerariesRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      _db.collection('users').doc(uid).collection('itineraries');

  Stream<List<Itinerary>> watchMine(String uid) => _col(uid)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) {
        final List<Itinerary> items =
            s.docs.map((d) => Itinerary.fromMap(d.id, d.data())).toList()
          ..sort((Itinerary a, Itinerary b) =>
              b.createdAt.compareTo(a.createdAt));
        return items;
      });

  Stream<Itinerary?> watchOne(String uid, String id) => _col(uid)
      .doc(id)
      .snapshots()
      .map((DocumentSnapshot<Map<String, dynamic>> d) {
        final Map<String, dynamic>? data = d.data();
        return data == null ? null : Itinerary.fromMap(d.id, data);
      });

  Future<String> create(String uid, Itinerary itinerary) =>
      _col(uid).add(itinerary.toMap()).then((ref) => ref.id);

  Future<void> remove(String uid, String id) =>
      _col(uid).doc(id).delete();
}
