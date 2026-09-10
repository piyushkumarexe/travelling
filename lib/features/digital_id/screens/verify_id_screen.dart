import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../data/models/digital_id.dart';

/// Verifies a Digital Emergency ID by its token (scanned from the QR code
/// or typed manually) against the live digitalIds collection.
class VerifyIdScreen extends StatefulWidget {
  const VerifyIdScreen({super.key});

  @override
  State<VerifyIdScreen> createState() => _VerifyIdScreenState();
}

enum _VerifyState { idle, verifying, verifiedActive, verifiedRevoked, notFound }

class _VerifyIdScreenState extends State<VerifyIdScreen> {
  AppContainer get _c => AppScope.of(context);

  final TextEditingController _tokenController = TextEditingController();
  _VerifyState _state = _VerifyState.idle;
  DigitalId? _result;
  String? _error;

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _verify(String rawToken) async {
    final String token = rawToken.trim().toLowerCase();
    if (token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Scan or enter a verification token.')),
        );
      }
      return;
    }
    if (!DigitalId.isValidTokenShape(token)) {
      if (mounted) {
        setState(() {
          _state = _VerifyState.notFound;
          _result = null;
        });
      }
      return;
    }
    if (mounted) setState(() => _state = _VerifyState.verifying);
    try {
      final DigitalId? id = await _c.digitalIdRepository.verify(token);
      if (!mounted) return;
      setState(() {
        _result = id;
        _state = id == null
            ? _VerifyState.notFound
            : (id.isActive
                ? _VerifyState.verifiedActive
                : _VerifyState.verifiedRevoked);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _VerifyState.idle;
        _error = e.toString();
      });
    }
  }

  Future<void> _scan() async {
    final String? token = await _openScanner();
    if (token != null && token.trim().isNotEmpty) {
      _tokenController.text = token.trim();
      await _verify(token);
    }
  }

  Future<String?> _openScanner() async {
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _ScannerDialog(
        onToken: (String t) => Navigator.of(ctx).pop(t),
      ),
    );
  }

  Future<void> _call(String phone) async {
    final Uri uri =
        Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Emergency ID')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (_state == _VerifyState.idle ||
              _state == _VerifyState.verifying)
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Enter or scan the verification token',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Tokens are 64 hex characters, shown under the QR code '
                    'on the person\'s Roamio Emergency ID card.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _tokenController,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: 'Verification token',
                      hintText: 'e.g. 3f2a… (64 characters)',
                      prefixIcon: Icon(Icons.key),
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(_error!, style: TextStyle(color: scheme.error)),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: PrimaryButton(
                          label: 'Scan QR code',
                          icon: Icons.qr_code_scanner,
                          outlined: true,
                          onPressed: _scan,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: PrimaryButton(
                          label: 'Verify',
                          icon: Icons.fact_check,
                          loading: _state == _VerifyState.verifying,
                          onPressed: _state == _VerifyState.verifying
                              ? null
                              : () => _verify(_tokenController.text),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_state == _VerifyState.verifying)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_state == _VerifyState.verifiedActive && _result != null)
            _resultCard(_result!, active: true),
          if (_state == _VerifyState.verifiedRevoked && _result != null)
            _resultCard(_result!, active: false),
          if (_state == _VerifyState.notFound)
            AppCard(
              child: Column(
                children: <Widget>[
                  const Icon(Icons.search_off,
                      size: 48, color: AppTheme.danger),
                  const SizedBox(height: 12),
                  Text(
                    'Token not recognized',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No active digital emergency ID matches this token. '
                    'Check that the token was scanned completely, or ask '
                    'the person to re-share their ID.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: 'Try another token',
                    icon: Icons.refresh,
                    outlined: true,
                    onPressed: () {
                      _tokenController.clear();
                      setState(() {
                        _state = _VerifyState.idle;
                        _result = null;
                        _error = null;
                      });
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _resultCard(DigitalId id, {required bool active}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            active ? const Color(0xFF0B3954) : const Color(0xFF37474F),
            active ? const Color(0xFF0E7C7B) : const Color(0xFF546E7A),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                active ? Icons.verified : Icons.block,
                color: active ? AppTheme.success : AppTheme.danger,
                size: 30,
              ),
              const SizedBox(width: 10),
              Text(
                active ? 'VERIFIED · ACTIVE' : 'VERIFIED · REVOKED',
                style: TextStyle(
                  color: active ? AppTheme.success : AppTheme.danger,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          CircleAvatar(
            radius: 34,
            backgroundColor: Colors.white24,
            child: id.photoUrl != null && id.photoUrl!.isNotEmpty
                ? ClipOval(
                    child: Image.network(
                      id.photoUrl!,
                      width: 68,
                      height: 68,
                      fit: BoxFit.cover,
                      errorBuilder: (BuildContext context, Object e,
                              StackTrace? s) =>
                          const Icon(Icons.person),
                    ),
                  )
                : const Icon(Icons.person, size: 36, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Text(
            id.ownerName,
            style: const TextStyle(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'ID created ${Fmt.date(id.createdAt)}',
            style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (id.emergencyContactName != null &&
              id.emergencyContactName!.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.contacts, color: Colors.white70),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Emergency contact',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 11),
                        ),
                        Text(
                          id.emergencyContactName!,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  if (id.emergencyContactPhone != null &&
                      id.emergencyContactPhone!.isNotEmpty)
                    Material(
                      color: Colors.white,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _call(id.emergencyContactPhone!),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.call,
                              color: AppTheme.danger, size: 20),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (id.emergencyContactPhone != null &&
              id.emergencyContactPhone!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Phone: ${id.emergencyContactPhone}',
                style: TextStyle(color: Colors.white.withOpacity(0.85)),
              ),
            ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'Verify another ID',
            icon: Icons.refresh,
            outlined: true,
            onPressed: () {
              _tokenController.clear();
              setState(() {
                _state = _VerifyState.idle;
                _result = null;
                _error = null;
              });
            },
          ),
        ],
      ),
    );
  }
}

class _ScannerDialog extends StatefulWidget {
  const _ScannerDialog({required this.onToken});

  final ValueChanged<String> onToken;

  @override
  State<_ScannerDialog> createState() => _ScannerDialogState();
}

class _ScannerDialogState extends State<_ScannerDialog> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  void _onDetect(BarcodeCapture result) {
    if (_handled) return;
    for (final Barcode barcode in result.barcodes) {
      final String? raw = barcode.rawValue;
      if (raw != null && raw.trim().isNotEmpty) {
        _handled = true;
        widget.onToken(raw);
        return;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Scan Emergency ID QR'),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
            Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.35),
              ),
            ),
            Center(
              child: SizedBox(
                width: 240,
                height: 240,
                child: CustomPaint(
                  painter: _ScannerFrame(),
                ),
              ),
            ),
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Text(
                'Point the camera at the QR code on the Emergency ID card',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.9), fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScannerFrame extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final double w = size.width;
    final double h = size.height;
    final double len = 34;
    canvas.drawLine(Offset(0, 0), Offset(len, 0), paint);
    canvas.drawLine(Offset(0, 0), Offset(0, len), paint);
    canvas.drawLine(Offset(w, 0), Offset(w - len, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, len), paint);
    canvas.drawLine(Offset(0, h), Offset(len, h), paint);
    canvas.drawLine(Offset(0, h), Offset(0, h - len), paint);
    canvas.drawLine(Offset(w, h), Offset(w - len, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - len), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
