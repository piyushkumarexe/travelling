import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Buttons with built-in loading state (no double submits, clear feedback).
///
/// Primary buttons use the uiverse-style signature gradient + neon glow.

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.outlined = false,
    this.danger = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool outlined;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool enabled = onPressed != null && !loading;

    final Color outlineColor =
        danger ? AppTheme.danger : scheme.primary;

    Widget contentRow(Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        );

    if (outlined) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: enabled ? onPressed : null,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            side: BorderSide(
              color: outlineColor.withValues(alpha: 0.7),
            ),
            foregroundColor: outlineColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: Center(
            child: loading
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: outlineColor,
                    ),
                  )
                : contentRow(outlineColor),
          ),
        ),
      );
    }

    final List<Color> gradientColors = !enabled
        ? <Color>[
            scheme.onSurface.withValues(alpha: 0.12),
            scheme.onSurface.withValues(alpha: 0.12),
          ]
        : danger
            ? const <Color>[Color(0xFFFF5A79), AppTheme.danger]
            : const <Color>[AppTheme.brandStart, AppTheme.brandEnd];
    final List<BoxShadow> shadows = !enabled
        ? const <BoxShadow>[]
        : AppTheme.glow(danger ? AppTheme.danger : AppTheme.brandStart);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: shadows,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onPressed : null,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Center(
              child: loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : contentRow(Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class IconButtonCircle extends StatelessWidget {
  const IconButtonCircle({
    super.key,
    required this.icon,
    this.onPressed,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? Theme.of(context).colorScheme.primary;
    return Material(
      color: c.withValues(alpha: 0.1),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: c),
        ),
      ),
    );
  }
}
