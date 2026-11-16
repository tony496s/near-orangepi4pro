import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/done_state.dart';
import '../../app/presenter.dart';
import '../../domain/tasks.dart';
import '../theme.dart';
import '../widgets/buttons.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

/// On the board taps land 35-40 px left of the finger, so buttons here take touches that far left of what is drawn
/// (only where nothing else is tappable).
const touchSlop = 40.0;

/// Right edge of everything on these screens above the timeline: left of the mic and VI/EN zone.
const doneRight = stripWidth - micZoneWidth - 24;

/// "MÁY NGHE ĐƯỢC": the sentence matched two open tasks about equally, so the strip asks which one is done, with two
/// big buttons, instead of guessing (demo 6, 14:35). "Nói lại" listens again. Whole strip, on the columns too.
class DoneChoiceScreen extends StatelessWidget {
  const DoneChoiceScreen({super.key, required this.c, required this.choice});
  final AppController c;
  final DoneChoice choice;

  static const optionsWidth = 620.0;
  static const optionHeight = 110.0;
  static const optionGap = 14.0;
  static const optionsLeft = doneRight - optionsWidth;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    return Sky(
      key: const Key('done-choice'),
      kind: SkyKind.at(now),
      child: Stack(
        children: [
          Positioned(
            left: 48,
            top: 40,
            width: optionsLeft - 48 - touchSlop,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('MÁY NGHE ĐƯỢC', style: eyebrow(color: Ink.dim)),
                const SizedBox(height: 12),
                Text('“${choice.heard}”',
                    maxLines: 3, overflow: TextOverflow.ellipsis, style: ts(36, weight: FontWeight.w500, height: 1.2)),
              ],
            ),
          ),
          Positioned(
            left: 48,
            top: 222,
            child: Row(
              children: [
                Text('CHƯA CHẮC · VIỆC NÀO ĐÃ XONG?', style: eyebrow(color: Ink.cool)),
                _Slop(
                  key: const Key('done-retry'),
                  onTap: c.retryDone,
                  child: Pill('Nói lại', small: true, onTap: c.retryDone),
                ),
              ],
            ),
          ),
          Positioned(
            left: optionsLeft - touchSlop,
            top: 36,
            width: optionsWidth + touchSlop,
            child: Column(
              children: [
                for (final (i, t) in choice.options.indexed) ...[
                  if (i > 0) const SizedBox(height: optionGap),
                  _Slop(
                    key: Key('done-option-$i'),
                    onTap: () => c.chooseDone(t),
                    child: _Option(task: t, due: dueLine(t, now)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.task, required this.due});
  final OpenTask task;
  final String due;

  @override
  Widget build(BuildContext context) => Container(
        height: DoneChoiceScreen.optionHeight,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        decoration: BoxDecoration(
          color: const Color(0x0FF2EEE6),
          border: Border.all(color: const Color(0x4DF2EEE6), width: 2),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.title,
                maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: ts(30, weight: FontWeight.w600, height: 1.2)),
            const SizedBox(height: 6),
            Text(due, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(17)),
          ],
        ),
      );
}

/// "ĐÃ ĐÁNH DẤU XONG": the task, what is still open, the day's timeline, and "Hoàn tác" for 8 seconds (its bar runs
/// down; then the screen goes and home comes back). The demo puts the undo block at right 44, under the mic zone on
/// the board, so it sits left of the mic here.
class DoneUndoScreen extends StatelessWidget {
  const DoneUndoScreen({super.key, required this.c, required this.done});
  final AppController c;
  final DoneUndo done;

  static const undoWidth = 250.0;
  static const undoLeft = doneRight - undoWidth;
  static const textLeft = 184.0;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final next = done.next;
    final rest = next == null
        ? 'Không còn việc nào'
        : 'Còn lại: ${next.title} · ${dueLine(next, now)}';
    final long = done.task.title.length > 26;
    return Sky(
      key: const Key('done-screen'),
      kind: SkyKind.done,
      glowX: Timeline.x(now).clamp(0, stripWidth),
      child: Stack(
        children: [
          const Positioned(left: 52, top: 52, child: SizedBox(width: 100, height: 100, child: CustomPaint(painter: _CheckPainter()))),
          Positioned(
            left: textLeft,
            top: 54,
            width: undoLeft - touchSlop - textLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ĐÃ ĐÁNH DẤU XONG', style: eyebrow(color: Ink.cool)),
                const SizedBox(height: 8),
                Text(done.task.title,
                    key: const Key('done-title'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: ts(long ? 38 : 50, weight: FontWeight.w600, height: 1.1)),
                const SizedBox(height: 10),
                Text(rest, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle()),
              ],
            ),
          ),
          Positioned(
            left: undoLeft - touchSlop,
            top: 56,
            width: undoWidth + touchSlop,
            child: _Slop(
              key: const Key('undo'),
              onTap: c.undoDone,
              child: Column(
                children: [
                  SizedBox(width: undoWidth, child: Pill('Hoàn tác', onTap: c.undoDone)),
                  const SizedBox(height: 14),
                  _UndoBar(fraction: done.remaining(now)),
                  const SizedBox(height: 8),
                  Text('Tự ẩn sau ${AppController.undoFor.inSeconds} giây', style: metaStyle(14)),
                ],
              ),
            ),
          ),
          Positioned(left: 0, top: 212, child: Timeline(events: c.plan.on(now), now: now, pins: todayPins(c))),
        ],
      ),
    );
  }
}

/// The undo time left, shrinking from the left; moves smoothly between the once-a-second ticks.
class _UndoBar extends StatelessWidget {
  const _UndoBar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const Key('undo-bar'),
        width: DoneUndoScreen.undoWidth,
        height: 4,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: Color(0x24F2EEE6), borderRadius: BorderRadius.all(Radius.circular(2))),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedContainer(
              key: const Key('undo-bar-fill'),
              duration: const Duration(seconds: 1),
              width: DoneUndoScreen.undoWidth * fraction,
              decoration: const BoxDecoration(color: Ink.cool, borderRadius: BorderRadius.all(Radius.circular(2))),
            ),
          ),
        ),
      );
}

/// A button that also takes taps [touchSlop] px left of it.
class _Slop extends StatelessWidget {
  const _Slop({super.key, required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.only(left: touchSlop), child: child),
      );
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter();

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
