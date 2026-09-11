import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/app_theme.dart';

/// Loading skeletons shown while real data loads (never fake data).

class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key, this.height = 120, this.radius = AppTheme.cardRadius});

  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color base = scheme.surfaceContainerHighest.withValues(alpha: 0.6);
    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: base.withValues(alpha: 0.35),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 4, this.height = 110});

  final int count;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List<Widget>.generate(count, (int i) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SkeletonCard(height: height),
          )),
    );
  }
}

class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key, this.height = 64, this.radius = 14});

  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color base = scheme.surfaceContainerHighest.withValues(alpha: 0.6);
    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: base.withValues(alpha: 0.35),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}
