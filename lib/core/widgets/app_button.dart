import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Buttons with built-in loading state (no double submits, clear feedback).
library;

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
    final Widget child = loading
        ? const SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18),
                const SizedBox(width: 8),
              ],
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          );
    if (outlined) {
      return OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(88, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Center(child: child),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: danger ? AppTheme.danger : scheme.primary,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
        child: Center(child: child),
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
    return Material(
      color: (color ?? Theme.of(context).colorScheme.primary).withOpacity(0.1),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: color),
        ),
      ),
    );
  }
}
