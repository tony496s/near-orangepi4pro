import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/presenter.dart';
import '../../core/vi_format.dart';
import '../theme.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

/// Morning brief (scenario 6, 08:25): the clock and date, today's meetings and longest free stretch, what is still
/// open from earlier days, and today's timeline with the first meeting lit. A tap anywhere goes back home.
class MorningBriefScreen extends StatelessWidget {
  const MorningBriefScreen({super.key, required this.c});
  final AppController c;

  /// Rows that fit between the list's eyebrow and the timeline (y 212) at 34 px each, as on the recap.
  static const maxRows = 4;
  static const midLeft = 450.0;
  static const midWidth = 300.0;
  static const listWidth = 462.0;
  static const rowHeight = 34.0;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final b = c.morningBrief;
    final carried = b.carried;
    final shown = carried.length > maxRows ? carried.take(maxRows - 1).toList() : carried;
    final more = carried.length - shown.length;
    final free = b.longestFree;
    return GestureDetector(
      key: const Key('morning-brief'),
      behavior: HitTestBehavior.opaque,
      onTap: c.dismissBrief,
      child: Sky(
        kind: SkyKind.at(now),
        glowX: Timeline.x(now).clamp(0, stripWidth),
        child: Stack(
          children: [
            Positioned(
              left: 44,
              top: 30,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CHÀO BUỔI SÁNG', style: eyebrow()),
                  const SizedBox(height: 12),
                  Text(hhmm(now), style: ts(84, weight: FontWeight.w300, spacing: -2, height: 1)),
                  const SizedBox(height: 10),
                  Text(shortDate(now), style: metaStyle()),
                ],
              ),
            ),
            Positioned(
              left: midLeft,
              top: 34,
              width: midWidth,
              child: _Rise(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('HÔM NAY', style: eyebrow(color: Ink.cool)),
                    const SizedBox(height: 6),
                    Text(b.meetings == 0 ? 'Không có họp' : '${b.meetings} cuộc họp',
                        maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: ts(34)),
                    const SizedBox(height: 10),
                    Text(free == null ? 'Không còn chỗ trống' : 'Rảnh dài nhất ${hhmm(free.start)} – ${hhmm(free.end)}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: metaStyle()),
                  ],
                ),
              ),
            ),
            if (carried.isNotEmpty)
              Positioned(
                right: micZoneWidth, // clear of the mic and VI/EN touch zones
                top: 30,
                width: listWidth,
                child: _Rise(
                  child: Column(
                    key: const Key('brief-list'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${carried.length} VIỆC TỪ HÔM QUA', style: eyebrow()),
                      const SizedBox(height: 4),
                      for (final item in shown) _Row(key: Key('brief-${item.id}'), text: item.text),
                      if (more > 0)
                        SizedBox(
                          height: rowHeight,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 28),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text('+$more việc nữa', maxLines: 1, style: metaStyle(19)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Positioned(
              left: 0,
              top: 212,
              child: Timeline(events: c.plan.on(now), now: now, pins: todayPins(c), highlightId: b.firstMeeting?.id),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: MorningBriefScreen.rowHeight,
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Ink.hot, width: 2)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: ts(19)),
            ),
          ],
        ),
      );
}

/// Fades in while rising 14 px, a moment after the screen appears (the demo's `.rise`: .55 s after a .15 s delay).
class _Rise extends StatelessWidget {
  const _Rise({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: const Interval(.15 / .7, 1, curve: Curves.ease),
        builder: (context, v, child) =>
            Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child)),
        child: child,
      );
}
