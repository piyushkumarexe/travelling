import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Consistent minimal card used across the app: clean surface, hairline
/// border and a soft drop shadow (uiverse-inspired "soft UI" look).
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
    return Container(
      decoration: BoxDecoration(
        color: color ?? (dark ? scheme.surfaceContainerLow : Colors.white),
        borderRadius: radius,
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: AppTheme.softShadow(context),
      ),
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
