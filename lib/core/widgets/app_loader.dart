import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Flutter-native interpretation of the requested Uiverse bouncing-ball loader.
class TravelBallLoader extends StatefulWidget {
  const TravelBallLoader({super.key, this.size = 72});

  final double size;

  @override
  State<TravelBallLoader> createState() => _TravelBallLoaderState();
}

class _TravelBallLoaderState extends State<TravelBallLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.primary;
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            final double wave = math.sin(_controller.value * math.pi);
            final double y = (1 - wave) * widget.size * 0.42;
            final double squash = wave < 0.08 ? 0.88 : 1;
            return Stack(
              alignment: Alignment.bottomCenter,
              children: <Widget>[
                Positioned(
                  bottom: 2,
                  child: Opacity(
                    opacity: 0.18 + wave * 0.22,
                    child: Transform.scale(
                      scaleX: 1.15 - wave * 0.45,
                      child: Container(
                        width: widget.size * 0.55,
                        height: widget.size * 0.09,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: y + widget.size * 0.1,
                  child: Transform.rotate(
                    angle: _controller.value * math.pi * 4,
                    child: Transform.scale(
                      scaleY: squash,
                      child: CustomPaint(
                        size: Size.square(widget.size * 0.42),
                        painter: _TravelBallPainter(color),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TravelBallPainter extends CustomPainter {
  const _TravelBallPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    final Paint fill = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.4),
        colors: <Color>[Color.lerp(color, Colors.white, 0.35)!, color],
      ).createShader(bounds);
    final Paint line = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, size.width * 0.045);
    canvas.drawOval(bounds.deflate(1), fill);
    canvas.drawOval(bounds.deflate(1), line);
    canvas.drawArc(bounds.deflate(size.width * 0.16), -1.3, 2.6, false, line);
    canvas.drawArc(bounds.deflate(size.width * 0.16), 1.85, 2.6, false, line);
    canvas.drawLine(
      Offset(size.width * 0.08, size.height * 0.5),
      Offset(size.width * 0.92, size.height * 0.5),
      line,
    );
  }

  @override
  bool shouldRepaint(_TravelBallPainter oldDelegate) => oldDelegate.color != color;
}
