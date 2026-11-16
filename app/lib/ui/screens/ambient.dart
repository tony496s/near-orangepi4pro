import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/presenter.dart';
import '../../core/vi_format.dart';
import '../theme.dart';
import '../widgets/gold_mini.dart';
import '../widgets/offline_note.dart';
import '../widgets/pulse.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';
import 'meeting_clock.dart';

/// The day strip: big clock, date, what is next (or the latest answer), a running plain timer, the timeline. Once
/// the gold chart was opened today, or while a price alert is armed ([AppController.goldMini]), a small gold tile
/// sits in the middle.
class AmbientScreen extends StatelessWidget {
  const AmbientScreen({super.key, required this.c});
  final AppController c;

  /// The right-hand block: right edge at the mic and VI/EN strip, this wide.
  static const blockWidth = 600.0;

  /// The gold tile (the demo's `.mid`): right of the clock and date (at their widest, e.g. "CHỦ NHẬT · 29 THÁNG
  /// MƯỜI MỘT", they end near x 405), above the timeline (y 212), and narrowed if needed to keep [miniGap] from the
  /// right-hand block.
  static const miniLeft = 450.0;
  static const miniTop = 34.0;
  static const miniGap = 10.0;
  static const _miniRoom = stripWidth - micZoneWidth - blockWidth - miniGap - miniLeft;
  static const miniWidth = _miniRoom < GoldMini.width ? _miniRoom : GoldMini.width;

  @override
  Widget build(BuildContext context) {
    // A meeting going on takes the strip (the meeting clock), unless a plain timer needs the middle.
    final m = c.meeting;
    final t = c.timer;
    final showMeeting = m != null && (t == null || t.focus);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: showMeeting
          ? MeetingClockScreen(key: const ValueKey('meeting-clock'), c: c, m: m)
          : KeyedSubtree(key: const ValueKey('day-strip'), child: _dayStrip()),
    );
  }

  Widget _dayStrip() {
    final now = c.now;
    final valid = c.clockValid;
    final block = stripBlock(c);
    final timer = c.timer;
    final plainTimer = timer != null && !timer.focus;
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
          // The plain timer takes the middle: no room for the tile there too, so it waits until the timer ends.
          if (c.goldMini && !plainTimer && !c.offline)
            Positioned(
              key: const ValueKey('gold-mini-slot'),
              left: miniLeft,
              top: miniTop,
              width: miniWidth,
              child: GoldMini(c: c),
            ),
          // Offline: the card takes the middle (the gold tile's prices need the network anyway); under a plain timer it
          // shrinks to one line.
          if (c.offline && !plainTimer)
            Positioned(left: miniLeft, top: miniTop, width: miniWidth, child: OfflineCard(c: c)),
          if (c.offline && plainTimer) Positioned(left: 470, top: 162, width: miniWidth, child: OfflineLine(c: c)),
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
            width: blockWidth,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: rise,
              child: _Block(key: ValueKey('${block.eyebrow}|${block.title}'), block: block),
            ),
          ),
          Positioned(
            left: 0,
            top: 212,
            child: Timeline(
                events: c.plan.on(now),
                now: valid ? now : null,
                pins: todayPins(c),
                highlightId: c.soonEventId,
                ghosts: c.movedSlots),
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
