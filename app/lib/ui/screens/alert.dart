import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/presenter.dart';
import '../theme.dart';
import '../widgets/buttons.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

/// Full-screen notice for a finished timer or a due reminder, with two big buttons.
class AlertScreen extends StatelessWidget {
  const AlertScreen({super.key, required this.c, required this.alert});
  final AppController c;
  final Alert alert;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final a = alertText(c, alert);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(a.eyebrow, style: eyebrow(color: a.done ? Ink.cool : Ink.ink)),
        const SizedBox(height: 10),
        Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(a.done ? 50 : 62, weight: FontWeight.w600, height: 1.05)),
        const SizedBox(height: 10),
        Text(a.meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle()),
      ],
    );
    return Sky(
      kind: a.done ? SkyKind.done : SkyKind.alert,
      glowX: Timeline.x(now).clamp(0, stripWidth),
      child: Stack(
        children: [
          if (a.done) const Positioned(left: 52, top: 50, child: _Check()),
          Positioned(left: a.done ? 184 : 48, top: a.done ? 46 : 38, width: a.done ? 760 : 880, child: text),
          Positioned(
            right: 44,
            top: 62,
            child: Row(
              children: [
                Pill(a.primary,
                    key: const Key('alert-primary'),
                    style: a.done ? PillStyle.cool : PillStyle.ink,
                    onTap: () => c.alertAction(AlertAction.primary)),
                const SizedBox(width: 16),
                Pill(a.secondary, key: const Key('alert-secondary'), onTap: () => c.alertAction(AlertAction.secondary)),
              ],
            ),
          ),
          Positioned(left: 0, top: 212, child: Timeline(events: c.plan.on(now), now: now, pins: todayPins(c))),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check();

  @override
  Widget build(BuildContext context) => SizedBox(width: 100, height: 100, child: CustomPaint(painter: _CheckPainter()));
}

class _CheckPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Ink.cool
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 1.5, p);
    p
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(size.width * .30, size.height * .52)
        ..lineTo(size.width * .45, size.height * .67)
        ..lineTo(size.width * .72, size.height * .36),
      p,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) => false;
}
