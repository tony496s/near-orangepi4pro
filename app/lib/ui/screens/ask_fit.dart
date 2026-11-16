import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/vi_format.dart';
import '../../domain/timer_fit.dart';
import '../theme.dart';
import '../widgets/buttons.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

/// "HẸN GIỜ 25 PHÚT?": a timer asked for would run into a meeting (demo 6, `timerConflict()`). The meeting and how
/// long until it on the left, the two answers on the right (left of the mic and VI/EN zone), and under them the next
/// half hour zoomed: the meeting zone, both timers as bars, the part that clashes tinted warm.
class AskFitScreen extends StatelessWidget {
  const AskFitScreen({super.key, required this.c, required this.ask});
  final AppController c;
  final AskFit ask;

  /// The answers end this far left of the mic and VI/EN zone: taps land 35-40 px left of the finger, so a tap aimed
  /// at the mic must not hit the last button.
  static const buttonsRight = micZoneWidth + 24;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final m = ask.meeting;
    final gap = clockMinutes(now, m.start);
    final asked = timerLength(ask.asked);
    final buttons = ask.canFit
        ? [
            Pill('Hẹn ${timerLength(ask.fit)}',
                key: const Key('ask-fit-fit'), style: PillStyle.ink, onTap: () => c.answerAskFit(AskFitAnswer.fit)),
            Pill('Vẫn $asked', key: const Key('ask-fit-asked'), onTap: () => c.answerAskFit(AskFitAnswer.asked)),
          ]
        : [
            Pill('Thôi', key: const Key('ask-fit-cancel'), style: PillStyle.ink, onTap: () => c.answerAskFit(AskFitAnswer.cancel)),
            Pill('Vẫn $asked', key: const Key('ask-fit-asked'), onTap: () => c.answerAskFit(AskFitAnswer.asked)),
          ];
    return Sky(
      key: const Key('ask-fit-screen'),
      kind: SkyKind.at(now),
      glowX: Timeline.x(now).clamp(0, stripWidth),
      child: Stack(
        children: [
          Positioned(
            left: 48,
            top: 42,
            right: buttonsRight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('HẸN GIỜ ${asked.toUpperCase()}?', style: eyebrow(color: Ink.cool)),
                      const SizedBox(height: 10),
                      Text('${hhmm(m.start)} có ${m.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: ts(52, weight: FontWeight.w600, height: 1.05)),
                      const SizedBox(height: 10),
                      Text(
                          gap > 0
                              ? 'Từ giờ tới lúc họp chỉ còn ${durationVi(Duration(minutes: gap))}'
                              : 'Cuộc họp bắt đầu ngay bây giờ',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle()),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Row(children: [buttons[0], const SizedBox(width: 24), buttons[1]]),
                ),
              ],
            ),
          ),
          Positioned(left: FitZoom.left, top: FitZoom.top, child: FitZoom(ask: ask, now: now)),
        ],
      ),
    );
  }
}

/// The next half hour (longer if the timer asked for ends later), the demo's `.zb`: ticks every 5 minutes, the
/// meeting zone from its start, the fitted timer (teal) and the one asked for (outlined) as bars from now, the part of
/// the latter inside the meeting tinted warm, and the "BÂY GIỜ" line.
class FitZoom extends StatelessWidget {
  const FitZoom({super.key, required this.ask, required this.now});
  final AskFit ask;
  final DateTime now;

  static const left = 44.0;
  static const top = 204.0;
  static const width = 1392.0;
  static const height = 116.0;

  /// The clash: a solid warm tint (diagonal stripes shimmered on the strip and hid the bar's label).
  static const clashFill = Color(0x4DFFB36B);

  /// Where the window starts: the 5 minutes now is in, one step earlier when now is less than 2 minutes in (room for
  /// the "BÂY GIỜ" label left of the line).
  static DateTime from(DateTime now) {
    final t = DateTime(now.year, now.month, now.day, now.hour, now.minute - now.minute % 5);
    return now.difference(t) < const Duration(minutes: 2) ? t.subtract(const Duration(minutes: 5)) : t;
  }

  /// The window in minutes: at least 30, up to the end of the asked timer and 10 minutes into the meeting, in 5s.
  static int span(AskFit a, DateTime now) {
    final f = from(now);
    final askedEnd = now.add(a.asked);
    final meetingRoom = a.meeting.start.add(const Duration(minutes: 10));
    final end = askedEnd.isAfter(meetingRoom) ? askedEnd : meetingRoom;
    final mins = (end.difference(f).inSeconds / 60).ceil();
    final rounded = (mins + 4) ~/ 5 * 5;
    return rounded < 30 ? 30 : rounded;
  }

  @override
  Widget build(BuildContext context) {
    final f = from(now);
    final minutes = span(ask, now);
    final px = width / minutes;
    double x(DateTime t) => (t.difference(f).inSeconds / 60 * px).clamp(0.0, width);
    final step = minutes <= 60 ? 5 : (minutes <= 120 ? 10 : 30);
    final m = ask.meeting;
    final zx = x(m.start);
    final nx = x(now);
    final askedEnd = now.add(ask.asked);
    final overX = x(askedEnd);
    final fitEnd = now.add(ask.fit);
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (var k = 0; k <= minutes; k += step) ...[
            Positioned(
                left: k * px - .5,
                top: 72,
                child: const SizedBox(width: 1, height: 5, child: ColoredBox(color: Ink.faint))),
            // The first and last labels sit inside the window (left / right aligned), not half cut off at its edges.
            Positioned(
              left: (k * px - 24).clamp(0.0, width - 48),
              width: 48,
              top: 82,
              child: Text(hhmm(f.add(Duration(minutes: k))),
                  textAlign: k * px < 24 ? TextAlign.left : (k * px > width - 24 ? TextAlign.right : TextAlign.center),
                  style: ts(13, weight: FontWeight.w500, color: Ink.faint, height: 1)),
            ),
          ],
          Positioned(
            key: const Key('ask-fit-zone'),
            left: zx,
            top: 4,
            width: width - zx,
            height: 70,
            child: Container(
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: Ink.hot, width: 2)),
                gradient: LinearGradient(colors: [Color(0x33FFB36B), Color(0x0AFFB36B)]),
              ),
              padding: const EdgeInsets.only(left: 12, top: 8, right: 8),
              alignment: Alignment.topLeft,
              child: Text('${m.title.toUpperCase()} · ${hhmm(m.start)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: ts(13, weight: FontWeight.w600, color: Ink.hot, spacing: 13 * .14)),
            ),
          ),
          if (ask.canFit)
            _bar(
              key: const Key('ask-fit-bar-fit'),
              left: nx,
              right: x(fitEnd),
              top: 12,
              text: '${timerLength(ask.fit)} · xong ${hhmm(fitEnd)}, trước họp ${clockMinutes(fitEnd, m.start)} phút',
              color: const Color(0x3886D8CC),
              border: Ink.cool,
              textColor: Ink.cool,
            ),
          // The part inside the meeting: a plain warm fill under the bar, so its outline and label stay on top.
          if (overX > zx)
            Positioned(
              key: const Key('ask-fit-clash'),
              left: zx,
              top: 42,
              width: overX - zx,
              height: 26,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  color: clashFill,
                  borderRadius: BorderRadius.horizontal(right: Radius.circular(7)),
                ),
              ),
            ),
          _bar(
            key: const Key('ask-fit-bar-asked'),
            left: nx,
            right: overX,
            top: 42,
            text: '${timerLength(ask.asked)} · lấn ${clockMinutes(m.start, askedEnd)} phút vào giờ họp',
            color: const Color(0x00000000),
            border: const Color(0x80F2EEE6),
            textColor: Ink.dim,
          ),
          Positioned(left: nx - 1, top: 4, child: const _NowLine()),
        ],
      ),
    );
  }

  Widget _bar({
    required Key key,
    required double left,
    required double right,
    required double top,
    required String text,
    required Color color,
    required Color border,
    required Color textColor,
  }) =>
      Positioned(
        key: key,
        left: left,
        top: top,
        width: (right - left).clamp(0.0, width),
        height: 26,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: color,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: ts(15, weight: FontWeight.w600, color: textColor, height: 1)),
        ),
      );
}

/// The demo's `.tl-now` in the zoom: a warm line with a dot and "BÂY GIỜ" on its left.
class _NowLine extends StatelessWidget {
  const _NowLine();

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 2,
        height: 74,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 4,
              child: Container(
                width: 2,
                height: 66,
                decoration: const BoxDecoration(color: Ink.hot, boxShadow: [BoxShadow(color: Color(0xCCFFB36B), blurRadius: 12)]),
              ),
            ),
            Positioned(
              left: -5,
              top: 0,
              child: Container(width: 12, height: 12, decoration: const BoxDecoration(color: Ink.hot, shape: BoxShape.circle)),
            ),
            Positioned(
              right: 14,
              top: -2,
              child: Text('BÂY GIỜ', softWrap: false, style: ts(12, weight: FontWeight.w600, color: Ink.hot, spacing: 12 * .16)),
            ),
          ],
        ),
      );
}
