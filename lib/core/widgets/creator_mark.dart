import 'package:flutter/material.dart';

/// A quiet creator signature styled like a shadcn secondary badge.
class CreatorMark extends StatelessWidget {
  const CreatorMark({super.key, this.padding = const EdgeInsets.all(8)});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Padding(
        padding: padding,
        child: Semantics(
          label: 'Made by Piyush',
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                'Made by Piyush',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
