import 'package:flutter/material.dart';

/// The Tourism brand mark, used on the login screen (and anywhere else the
/// app shows its identity).
///
/// It resolves the PNG first and falls back to the bundled JPEG, so swapping
/// the artwork is a plain file copy into `assets/images/yatrawise-logo.png` —
/// no code change, and the build never breaks while only one of the two files
/// exists (a missing asset would otherwise throw inside [Image.asset]).
class AppLogo extends StatelessWidget {
  const AppLogo({
    super.key,
    this.size = 120,
    this.radius = 28,
    this.shadow = true,
  });

  final double size;
  final double radius;

  /// Soft drop shadow, matching the login card style.
  final bool shadow;

  static const String pngAsset = 'assets/images/yatrawise-logo.png';
  static const String jpgAsset = 'assets/images/yatrawise-logo.jpg';

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        // The logo artwork has a light background; without this it would sit
        // on the app background and look like a cut-out in dark mode.
        color: dark ? Colors.white : const Color(0xFFFFFDF7),
        boxShadow: shadow
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 1),
        child: Image.asset(
          pngAsset,
          fit: BoxFit.cover,
          errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
              Image.asset(
            jpgAsset,
            fit: BoxFit.cover,
            errorBuilder: (BuildContext c2, Object e2, StackTrace? s2) =>
                const Center(
              child: Icon(Icons.place, size: 48, color: Colors.black54),
            ),
          ),
        ),
      ),
    );
  }
}
