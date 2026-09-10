import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Real Google Sign-In + Firebase Authentication.
library;

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AuthRepository {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final GoogleSignIn _google = GoogleSignIn();

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Future<User?> signInWithGoogle() async {
    try {
      final GoogleSignInAccount? account = await _google.signIn();
      if (account == null) {
        throw AuthException('Google sign-in was cancelled.');
      }
      final GoogleSignInAuthentication authentication =
          await account.authentication;
      final UserCredential result = await _auth.signInWithCredential(
        GoogleAuthProvider.credential(
          accessToken: authentication.accessToken,
          idToken: authentication.idToken,
        ),
      );
      final User? user = result.user;
      if (user == null) {
        throw AuthException('Sign-in did not complete. Please try again.');
      }
      return user;
    } on AuthException {
      rethrow;
    } on FirebaseAuthException catch (e) {
      throw AuthException(_friendlyAuthError(e));
    } catch (_) {
      throw AuthException('Google sign-in failed. Please try again.');
    }
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'invalid-firebase-credential':
        return 'Google credential was not accepted. Try signing in again.';
      case 'account-exists-with-different-credential':
        return 'This Google account is already linked to another Roamio account.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a minute and try again.';
      case 'network-request-failed':
        return 'Network error during sign-in. Check your connection.';
      default:
        return 'Sign-in failed (${e.code}). Please try again.';
    }
  }

  Future<void> signOut() async {
    try {
      await _google.signOut();
    } catch (_) {
      // ignore
    }
    try {
      await _auth.signOut();
    } catch (_) {
      // ignore
    }
  }

  /// Creates the `users/{uid}` and `profiles/{uid}` documents on first
  /// login. Idempotent — a no-op for returning users.
  Future<void> ensureProfile(User user) async {
    final DocumentReference<Map<String, dynamic>> userRef =
        _db.collection('users').doc(user.uid);
    final DocumentSnapshot<Map<String, dynamic>> userSnap = await userRef.get();
    if (userSnap.exists) return;

    await userRef.set(<String, dynamic>{
      'uid': user.uid,
      'displayName': user.displayName ?? '',
      'email': user.email ?? '',
      'photoUrl': user.photoURL,
      'role': 'user',
      'createdAt': Timestamp.now(),
    });

    final DocumentReference<Map<String, dynamic>> profileRef =
        _db.collection('profiles').doc(user.uid);
    final DocumentSnapshot<Map<String, dynamic>> profileSnap =
        await profileRef.get();
    if (!profileSnap.exists) {
      await profileRef.set(<String, dynamic>{
        'uid': user.uid,
        'name': user.displayName ?? '',
        'photoUrl': user.photoURL,
        'language': 'en',
        'emergencyContactName': '',
        'emergencyContactPhone': '',
        'interests': <String>[],
        'budget': 'mid',
        'travelStyle': 'balanced',
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      });
    }
  }

  /// Streams the user's role from Firestore (used to gate the admin area).
  Stream<Map<String, dynamic>?> watchUserData(String uid) =>
      _db.collection('users').doc(uid).snapshots().map(
            (DocumentSnapshot<Map<String, dynamic>> d) =>
                d.exists ? d.data() : null,
          );
}
