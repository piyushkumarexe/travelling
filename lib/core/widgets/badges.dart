import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Small colored pill badges for risk levels and statuses.

class RiskBadge extends StatelessWidget {
  const RiskBadge({super.key, required this.risk});

  final String risk;

  static Color colorFor(BuildContext context, String risk) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return switch (risk) {
      'low' => AppTheme.success,
      'medium' => AppTheme.warning,
      'high' => const Color(0xFFE8590C),
      _ => AppTheme.danger,
    };
  }

  @override
  Widget build(BuildContext context) {
    final Color bg = colorFor(context, risk);
    final String label = switch (risk) {
      'low' => 'Low risk',
      'medium' => 'Medium',
      'high' => 'High risk',
      _ => 'Critical',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: bg.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: bg,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color c = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withOpacity(0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: c,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
