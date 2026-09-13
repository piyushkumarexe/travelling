import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Uiverse-style "bouncing dots" loading animation.
///
/// Three dots that hop in sequence with a soft fade — a friendlier,
/// branded loading state than the default circular spinner.
class LoadingIndicator extends StatefulWidget {
  const LoadingIndicator({
    super.key,
    this.color,
    this.dotSize = 10,
    this.spacing = 8,
  });

  /// Dot color; defaults to the theme primary color.
  final Color? color;

  /// Diameter of a single dot.
  final double dotSize;

  /// Horizontal gap between dots.
  final double spacing;

  @override
  State<LoadingIndicator> createState() => _LoadingIndicatorState();
}

class _LoadingIndicatorState extends State<LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color =
        widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < 3; i++)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.spacing / 2),
                child: _Dot(
                  color: color,
                  size: widget.dotSize,
                  // Each dot trails the previous one by a third of the cycle.
                  phase: (i * 1 / 3 + _controller.value) % 1.0,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size, required this.phase});

  final Color color;
  final double size;
  final double phase;

  @override
  Widget build(BuildContext context) {
    // Sine wave: rises to peak at phase 0.5 and falls back down.
    final double wave = math.sin(phase * math.pi);
    final double lift = -wave * (size * 0.9);
    final double opacity = 0.35 + 0.65 * wave;
    return Transform.translate(
      offset: Offset(0, lift),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: opacity),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
