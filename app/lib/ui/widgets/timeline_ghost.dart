import 'package:flutter/widgets.dart';

import '../theme.dart';

/// The old slot of a moved event on the timeline (the demo's `.tl-ghost`): a dashed rounded outline, no fill, where
/// the event used to be.
class TimelineGhost extends StatelessWidget {
  const TimelineGhost({super.key});

  /// Positioned like an event box from [x0] to [x1] on the timeline.
  static Widget at(double x0, double x1) => Positioned(
        key: ValueKey('timeline-ghost-${x0.round()}'),
        left: x0,
        top: 30,
        width: (x1 - x0 - 3).clamp(4.0, stripWidth),
        height: 38,
        child: const TimelineGhost(),
      );

  /// `.tl-ev.moved`: the moved event's teal fill.
  static const movedFill = Color(0x3D86D8CC);
  static const _line = Color(0x73F2EEE6); // .45

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _DashedBox());
}

class _DashedBox extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius((Offset.zero & size).deflate(.5), const Radius.circular(8));
    final paint = Paint()
      ..color = TimelineGhost._line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in (Path()..addRRect(rrect)).computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, (d + 4).clamp(0, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => false;
}
