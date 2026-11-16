import 'package:flutter/widgets.dart';

import '../theme.dart';

/// The strip background: a vertical gradient with a soft elliptical glow rising from below at [glowX]
/// (the CSS `radial-gradient(560px 280px at x 340px, glow, transparent 70%)` of the demo).
class Sky extends StatelessWidget {
  const Sky({super.key, required this.kind, this.glowX = 740, this.child});

  final SkyKind kind;
  final double glowX;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _SkyPainter(kind, glowX), child: child);
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.kind, this.glowX);
  final SkyKind kind;
  final double glowX;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [kind.top, kind.bottom],
        ).createShader(rect),
    );
    canvas.save();
    canvas.clipRect(rect);
    canvas.translate(glowX, 340);
    canvas.scale(1, 280 / 560);
    const r = 560.0;
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..shader = RadialGradient(colors: [kind.glow, kind.glow.withValues(alpha: 0)], stops: const [0, .7])
            .createShader(Rect.fromCircle(center: Offset.zero, radius: r)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SkyPainter old) => old.kind != kind || old.glowX != glowX;
}
