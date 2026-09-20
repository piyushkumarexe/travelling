import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Consistent glass card used across the app: translucent gradient surface,
/// hairline border and a soft drop shadow (uiverse-style glassmorphism).
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final BorderRadius radius = BorderRadius.circular(AppTheme.cardRadius);
    final Widget content = Padding(padding: padding, child: child);

    final BoxDecoration decoration;
    if (color != null) {
      decoration = BoxDecoration(
        color: color,
        borderRadius: radius,
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.10)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
        boxShadow: AppTheme.softShadow(context),
      );
    } else {
      decoration = AppTheme.cardBox(context);
    }

    return Container(
      decoration: decoration,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        child: onTap == null
            ? content
            : InkWell(
                borderRadius: radius,
                onTap: onTap,
                child: content,
              ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}
