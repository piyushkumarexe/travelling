import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_config.dart';
import '../../../core/state/app_container.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../data/repositories/auth_repository.dart'
    show AuthException;

/// Login / sign-up screen: email + password and Google Sign-In
/// (both backed by Firebase Authentication).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _AuthMode { signIn, signUp }

class _LoginScreenState extends State<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  _AuthMode _mode = _AuthMode.signIn;
  bool _loading = false;
  bool _obscure = true;
  bool _resetSending = false;

  AppContainer get _c => AppScope.of(context);

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _isSignUp => _mode == _AuthMode.signUp;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit() async {
    if (_loading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _loading = true);
    try {
      if (_isSignUp) {
        await _c.authRepository.registerWithEmailAndPassword(
          _email.text,
          _password.text,
        );
      } else {
        await _c.authRepository.signInWithEmailAndPassword(
          _email.text,
          _password.text,
        );
      }
      // AuthState reacts to the auth stream; the router redirects to /home.
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (_) {
      _showSnack('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await _c.authRepository.signInWithGoogle();
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (_) {
      _showSnack('Google sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final String? email = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _ForgotPasswordDialog(
        initialEmail: _email.text.trim(),
      ),
    );
    if (email == null || email.trim().isEmpty || !mounted) return;
    setState(() => _resetSending = true);
    try {
      await _c.authRepository.sendPasswordReset(email.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Reset link sent to $email — check your inbox.'),
        ),
      );
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (_) {
      _showSnack('Could not send the reset email. Please try again.');
    } finally {
      if (mounted) setState(() => _resetSending = false);
    }
  }

  void _switchMode() {
    if (_loading) return;
    final String email = _email.text;
    setState(() {
      _mode = _isSignUp ? _AuthMode.signIn : _AuthMode.signUp;
    });
    _formKey.currentState?.reset();
    // Keep the email the user already typed; clear only the passwords.
    _email.text = email;
    _password.clear();
    _confirm.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding:
                const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: scheme.outline),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black
                              .withValues(alpha: dark ? 0.35 : 0.10),
                          blurRadius: 28,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Image.asset(
                        'assets/images/yatrawise-logo.jpg',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  _isSignUp ? 'Create your account' : 'Welcome back',
                  style: text.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _isSignUp
                      ? 'Sign up with your email to get started.'
                      : 'Sign in with your email and password.',
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        autofillHints: const <String>[
                          AutofillHints.email,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.mail_outline),
                          border: OutlineInputBorder(),
                        ),
                        validator: Validators.email,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        textInputAction: _isSignUp
                            ? TextInputAction.next
                            : TextInputAction.done,
                        autofillHints: <String>[
                          _isSignUp
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (String? v) =>
                            Validators.password(v, isSignUp: _isSignUp),
                        onFieldSubmitted: (_) {
                          if (!_isSignUp) unawaited(_submit());
                        },
                      ),
                      if (_isSignUp) ...<Widget>[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirm,
                          obscureText: _obscure,
                          textInputAction: TextInputAction.done,
                          autofillHints: const <String>[
                            AutofillHints.newPassword,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Confirm password',
                            prefixIcon: Icon(Icons.lock_reset),
                            border: OutlineInputBorder(),
                          ),
                          validator: (String? v) {
                            if ((v ?? '').isEmpty) {
                              return 'Re-enter your password.';
                            }
                            if (v != _password.text) {
                              return 'Passwords do not match.';
                            }
                            return null;
                          },
                          onFieldSubmitted: (_) => unawaited(_submit()),
                        ),
                      ],
                      const SizedBox(height: 24),
                      PrimaryButton(
                        label: _loading
                            ? 'Please wait…'
                            : _isSignUp
                                ? 'Create account'
                                : 'Sign in',
                        icon: _loading
                            ? null
                            : _isSignUp
                                ? Icons.person_add_alt
                                : Icons.login,
                        loading: _loading,
                        onPressed: _submit,
                      ),
                    ],
                  ),
                ),
                if (!_isSignUp) ...<Widget>[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _resetSending ? null : _forgotPassword,
                      child: const Text('Forgot password?'),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'or',
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _signInWithGoogle,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: const Icon(Icons.account_circle),
                  label: const Text('Continue with Google'),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      _isSignUp
                          ? 'Already have an account?'
                          : 'New to Tourism?',
                      style: text.bodyMedium,
                    ),
                    TextButton(
                      onPressed: _loading ? null : _switchMode,
                      child: Text(_isSignUp ? 'Sign in' : 'Create account'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Sign in to save itineraries, incidents, your digital '
                  'emergency ID and eco progress. Your data is private — '
                  'only you (and authorized administrators for safety '
                  'features) can access it.',
                  style: text.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Tourism v${AppConfig.appVersion}',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ForgotPasswordDialog extends StatefulWidget {
  const _ForgotPasswordDialog({this.initialEmail = ''});

  final String initialEmail;

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail);

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reset password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'Enter your email and we will send you a link to reset your '
            'password.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_email.text),
          child: const Text('Send link'),
        ),
      ],
    );
  }
}
