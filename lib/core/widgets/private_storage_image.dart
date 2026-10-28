import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

/// Loads new private media through authenticated Firebase Storage SDK access.
/// [legacyUrl] is only a read-compatibility path for existing bearer URLs.
class PrivateStorageImage extends StatefulWidget {
  const PrivateStorageImage({
    super.key,
    this.storagePath,
    this.legacyUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.maxBytes = 10 * 1024 * 1024,
    this.placeholder,
  });

  final String? storagePath;
  final String? legacyUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final int maxBytes;
  final Widget? placeholder;

  @override
  State<PrivateStorageImage> createState() => _PrivateStorageImageState();
}

class _PrivateStorageImageState extends State<PrivateStorageImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PrivateStorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storagePath != widget.storagePath ||
        oldWidget.legacyUrl != widget.legacyUrl) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final String path = widget.storagePath?.trim() ?? '';
    if (path.isEmpty) return;
    try {
      final Uint8List? bytes =
          await FirebaseStorage.instance.ref(path).getData(widget.maxBytes);
      if (!mounted || path != widget.storagePath) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _failed = true);
      } else {
        setState(() => _bytes = bytes);
      }
    } catch (_) {
      if (mounted && path == widget.storagePath) {
        setState(() => _failed = true);
      }
    }
  }

  Widget get _fallback =>
      widget.placeholder ??
      const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.broken_image_outlined)),
      );

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallback,
      );
    }
    final String path = widget.storagePath?.trim() ?? '';
    if (path.isNotEmpty && !_failed) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (path.isNotEmpty && _failed) return _fallback;
    final String legacy = widget.legacyUrl?.trim() ?? '';
    if (legacy.isNotEmpty) {
      return Image.network(
        legacy,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: (_, __, ___) => _fallback,
      );
    }
    return _fallback;
  }
}
