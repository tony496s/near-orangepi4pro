import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/presenter.dart';
import '../../core/vi_format.dart';
import '../theme.dart';
import '../widgets/pulse.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

/// The day strip: big clock, date, what is next (or the latest answer), a running plain timer, the timeline.
class AmbientScreen extends StatelessWidget {
  const AmbientScreen({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final valid = c.clockValid;
    final block = stripBlock(c);
    final timer = c.timer;
    return Sky(
      kind: SkyKind.at(now),
      glowX: Timeline.x(now).clamp(0, stripWidth),
      child: Stack(
        children: [
          Positioned(
            left: 40,
            top: 16,
            child: Text(valid ? hhmm(now) : '--:--', style: ts(128, weight: FontWeight.w300, spacing: -4, height: 1)),
          ),
          Positioned(
            left: 46,
            top: 160,
            child: Text(valid ? dateLine(now) : 'ĐANG CHỜ GIỜ CHUẨN',
                style: ts(17, weight: FontWeight.w500, color: Ink.dim, spacing: 17 * .16)),
          ),
          if (timer != null && !timer.focus)
            Positioned(
              left: 470,
              top: 36,
              child: Column(
                key: const Key('plain-timer'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('HẸN GIỜ · ${durationVi(timer.duration).toUpperCase()}', style: eyebrow(color: Ink.cool)),
                  const SizedBox(height: 6),
                  Text(mmss(timer.remaining(now)), style: ts(56, weight: FontWeight.w300, spacing: -1, height: 1)),
                  const SizedBox(height: 6),
                  Text('Kết thúc ${hhmm(timer.endsAt)}', style: metaStyle(17)),
                ],
              ),
            ),
          Positioned(
            right: micZoneWidth,
            top: 30,
            width: 600,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: rise,
              child: _Block(key: ValueKey('${block.eyebrow}|${block.title}'), block: block),
            ),
          ),
          Positioned(
            left: 0,
            top: 212,
            child: Timeline(events: c.plan.on(now), now: valid ? now : null, pins: todayPins(c), highlightId: c.soonEventId),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({super.key, required this.block});
  final StripBlock block;

  @override
  Widget build(BuildContext context) {
    final long = block.title.length > 22;
    final title = Text(
      block.title,
      textAlign: TextAlign.right,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: ts(long ? 34 : 46, weight: FontWeight.w600, height: 1.12),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(block.eyebrow, style: eyebrow(color: block.cool ? Ink.cool : Ink.hot)),
        SizedBox(height: long ? 12 : 8),
        block.pulse ? Pulse(child: title) : title,
        const SizedBox(height: 10),
        Text(block.meta, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle()),
      ],
    );
  }
}
