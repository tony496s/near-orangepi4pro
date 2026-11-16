import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/live_presenter.dart';
import '../../app/presenter.dart';
import '../theme.dart';
import '../widgets/offline_note.dart';
import '../widgets/pulse.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

/// The day strip while a meeting is going on (scenario 6, 11:39: "liếc xuống là biết còn bao lâu"): what the meeting
/// is and what comes after on the left, a big countdown to its end on the right, the timeline with the meeting lit.
/// An answer the user asks for takes the left block for a moment; the countdown stays.
class MeetingClockScreen extends StatelessWidget {
  const MeetingClockScreen({super.key, required this.c, required this.m});
  final AppController c;
  final MeetingClock m;

  /// Left text block: from x 48 up to the countdown, which ends at the mic zone.
  static const leftX = 48.0;
  static const leftWidth = 800.0;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final f = c.flash;
    final (eb, title, meta, cool) = f == null ? (m.eyebrow, m.event.title, m.after, false) : (f.eyebrow, f.title, f.meta, f.cool);
    final long = title.length > 26;
    return Sky(
      kind: SkyKind.at(now),
      glowX: Timeline.x(now).clamp(0, stripWidth),
      child: Stack(
        children: [
          Positioned(
            left: leftX,
            top: 42,
            width: leftWidth,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: rise,
              child: Column(
                key: ValueKey('meeting-left|$eb|$title'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(eb, maxLines: 1, overflow: TextOverflow.ellipsis, style: eyebrow(color: cool ? Ink.cool : Ink.hot)),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    key: const Key('meeting-title'),
                    maxLines: long ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(long ? 34 : 52, weight: FontWeight.w600, height: long ? 1.12 : 1.05),
                  ),
                  const SizedBox(height: 10),
                  Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle()),
                ],
              ),
            ),
          ),
          Positioned(
            right: micZoneWidth,
            top: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(m.countdown,
                    key: const Key('meeting-countdown'), style: ts(136, weight: FontWeight.w200, spacing: -4, height: 1)),
                const SizedBox(height: 8),
                Text(m.sub, style: eyebrow(color: Ink.dim)),
                if (c.offline) ...[const SizedBox(height: 6), OfflineLine(c: c)],
              ],
            ),
          ),
          Positioned(
            left: 0,
            top: 212,
            child: Timeline(
                events: c.plan.on(now), now: now, pins: todayPins(c), highlightId: m.event.id, ghosts: c.movedSlots),
          ),
        ],
      ),
    );
  }
}
