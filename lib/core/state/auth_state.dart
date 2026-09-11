import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../data/repositories/auth_repository.dart';

enum AuthStatus { initial, unauthenticated, authenticated }

/// App-wide authentication state (streaming from Firebase Auth) plus the
/// user's role from Firestore (admin gating).
class AuthState extends ChangeNotifier {
  AuthState(this._repo);

  final AuthRepository _repo;

  User? _user;
  bool _isAdmin = false;
  AuthStatus _status = AuthStatus.initial;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<Map<String, dynamic>?>? _userDocSub;

  User? get user => _user;
  bool get isAdmin => _isAdmin;
  AuthStatus get status => _status;

  void start() {
    if (_authSub != null) return;
    _authSub = _repo.authStateChanges().listen(
      _onAuth,
      onError: (Object e) {
        debugPrint('AuthState stream error: $e');
      },
    );
  }

  void _onAuth(User? u) {
    _user = u;
    _status =
        u == null ? AuthStatus.unauthenticated : AuthStatus.authenticated;
    _isAdmin = false;
    _userDocSub?.cancel();
    _userDocSub = null;
    if (u != null) {
      unawaited(
        _repo.ensureProfile(u).catchError((Object e) {
          debugPrint('AuthState ensureProfile: $e');
        }),
      );
      _userDocSub = _repo.watchUserData(u.uid).listen(
        (Map<String, dynamic>? d) {
          final bool admin = (d?['role'] as String?) == 'admin';
          if (admin != _isAdmin) {
            _isAdmin = admin;
            notifyListeners();
          }
        },
        onError: (Object e) {
          debugPrint('AuthState user doc stream error: $e');
        },
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _userDocSub?.cancel();
    super.dispose();
  }
}
