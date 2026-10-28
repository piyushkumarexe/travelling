import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/app_config.dart';

/// Real Google Sign-In + Firebase Authentication.

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AuthRepository {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // `serverClientId` (the Google Sign-In *web* client ID) is required on
  // Android when there is no google-services.json, otherwise the ID token is
  // null and Firebase rejects the credential.
  final GoogleSignIn _google = GoogleSignIn(
    serverClientId: AppConfig.googleWebClientId.isEmpty
        ? null
        : AppConfig.googleWebClientId,
  );

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
    } catch (e) {
      debugPrint('Google sign-in error: $e');
      throw AuthException(_googleSignInError(e));
    }
  }

  /// Turns the platform exception Google Sign-In throws into an actionable
  /// message. The most common causes are a missing/mismatched SHA-1 on the
  /// Android OAuth client (error 10) or an unpublished OAuth consent screen.
  String _googleSignInError(Object e) {
    String detail = '';
    if (e is PlatformException) {
      detail = (e.message ?? e.code).trim();
    } else {
      detail = e.toString();
    }
    final RegExp apiErr = RegExp(r'ApiException:\s*(\d+)');
    final RegExpMatch? match = apiErr.firstMatch(detail);
    if (match != null) {
      switch (match.group(1)) {
        case '10':
          return 'Google Sign-In is not configured correctly for this app '
              '(error 10). Check that this app\'s SHA-1 fingerprint and '
              'package name are registered on the Android OAuth client.';
        case '12501':
          return 'Google Sign-In was cancelled or blocked (error 12501). '
              'Check that the OAuth consent screen is published and the '
              'correct SHA-1 is registered.';
        case '12500':
          return 'Google Sign-In failed (error 12500). Check the Web client '
              'ID and that the OAuth consent screen is published.';
      }
    }
    final String short =
        detail.length > 180 ? '${detail.substring(0, 180)}…' : detail;
    return 'Google sign-in failed. $short';
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'invalid-firebase-credential':
        return 'Google credential was not accepted. Try signing in again.';
      case 'account-exists-with-different-credential':
        return 'An account already exists with this email. Sign in with the '
            'method you used before.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a minute and try again.';
      case 'network-request-failed':
        return 'Network error during sign-in. Check your connection.';
      case 'invalid-email':
        return 'That email address looks invalid.';
      case 'user-not-found':
      case 'user-disabled':
        return 'No account found for this email. Create one first.';
      case 'wrong-password':
      case 'invalid-password':
        return 'Incorrect password. Try again or reset it.';
      case 'email-already-in-use':
        return 'This email is already registered. Sign in instead.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is not enabled for this project yet.';
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

  /// Email + password sign-in.
  Future<User?> signInWithEmailAndPassword(
      String email, String password) async {
    try {
      final UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return result.user;
    } on FirebaseAuthException catch (e) {
      throw AuthException(_friendlyAuthError(e));
    } catch (_) {
      throw AuthException('Sign-in failed. Please try again.');
    }
  }

  /// Email + password sign-up (creates the account and signs the user in).
  Future<User?> registerWithEmailAndPassword(
      String email, String password) async {
    try {
      final UserCredential result =
          await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return result.user;
    } on FirebaseAuthException catch (e) {
      throw AuthException(_friendlyAuthError(e));
    } catch (_) {
      throw AuthException('Could not create your account. Please try again.');
    }
  }

  /// Sends a password-reset email.
  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw AuthException(_friendlyAuthError(e));
    } catch (_) {
      throw AuthException('Could not send the reset email. Please try again.');
    }
  }

  /// Creates the `users/{uid}` and `profiles/{uid}` documents on first
  /// login. Idempotent — a no-op for returning users.
  Future<void> ensureProfile(User user) async {
    final DocumentReference<Map<String, dynamic>> userRef =
        _db.collection('users').doc(user.uid);
    final DocumentSnapshot<Map<String, dynamic>> userSnap = await userRef.get();
    if (!userSnap.exists) {
      // Only write the fields the Firestore `users/{uid}` create rule allows
      // (role, displayName, email, createdAt). Extra fields such as `uid` or
      // `photoUrl` make the write fail permission-denied, which used to leave
      // users WITHOUT a profile document.
      await userRef.set(<String, dynamic>{
        'displayName': user.displayName ?? '',
        'email': user.email ?? '',
        'role': 'user',
        'createdAt': Timestamp.now(),
      });
    }

    // Always make sure the profile document exists too (independent of the
    // users doc, so a missing profile is repaired on next sign-in).
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
