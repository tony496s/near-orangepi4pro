import 'package:flutter/widgets.dart';

import '../../app/presenter.dart';
import '../../core/vi_format.dart';
import '../../domain/calendar_diff.dart';
import '../../domain/models.dart';
import '../theme.dart';
import 'timeline_ghost.dart';

/// The day from 07:00 to 21:00 across the full width: hour marks, events, reminder pins and a "now" line.
class Timeline extends StatelessWidget {
  const Timeline({super.key, required this.events, this.now, this.pins = const [], this.highlightId, this.ghosts = const []});

  static const startHour = 7;
  static const endHour = 21;
  static const pxPerHour = stripWidth / (endHour - startHour);
  static const height = 108.0;

  final List<CalendarEvent> events;

  /// Null for a day that is not today (no "now" line, nothing dimmed).
  final DateTime? now;
  final List<Pin> pins;
  final String? highlightId;

  /// Old slots of moved events: a dashed outline under the events; the moved event is tinted teal.
  final List<MovedSlot> ghosts;

  static double x(DateTime t) => ((t.hour + t.minute / 60 + t.second / 3600) - startHour) * pxPerHour;

  /// Below this, a label placed after a short event is dropped rather than squeezed to a couple of letters.
  static const minOutsideLabel = 36.0;

  static const _boxPadding = 9.0;

  /// Events drawn on the timeline, by start time (deadlines have no box).
  List<CalendarEvent> get _shown =>
      [...events.where((e) => e.kind != EventKind.deadline)]..sort((a, b) => a.start.compareTo(b.start));

  static TextStyle get _labelStyle => ts(14, weight: FontWeight.w500);

  static double _textWidth(String text) {
    final tp = TextPainter(text: TextSpan(text: text, style: _labelStyle), textDirection: TextDirection.ltr, maxLines: 1)
      ..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final n = now;
    final nx = n == null ? null : x(n).clamp(0.0, stripWidth);
    return SizedBox(
      width: stripWidth,
      height: height,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          if (nx != null)
            Positioned(
              left: 0,
              top: 24,
              width: nx,
              height: 52,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0x33000000), Color(0x0A000000)]),
                ),
              ),
            ),
          for (var h = startHour + 1; h < endHour; h++) ...[
            Positioned(
              left: (h - startHour) * pxPerHour - .5,
              top: 72,
              child: const SizedBox(width: 1, height: 5, child: ColoredBox(color: Ink.faint)),
            ),
            Positioned(
              left: (h - startHour) * pxPerHour - 20,
              width: 40,
              top: 82,
              child: Text(two(h), textAlign: TextAlign.center, style: ts(13, weight: FontWeight.w500, color: Ink.faint, height: 1)),
            ),
          ],
          for (final g in ghosts) TimelineGhost.at(x(g.start), x(g.end)),
          for (final (i, e) in _shown.indexed) ..._event(e, n, _labelLimit(e, i)),
          for (final p in pins) _pin(p),
          if (nx != null) _nowLine(nx),
        ],
      ),
    );
  }

  /// The box, and for a short event whose title does not fit inside, a label after it that stops before [nextX]
  /// (the start of the next event) so labels never run over other events.
  List<Widget> _event(CalendarEvent e, DateTime? n, double nextX) {
    final x0 = x(e.start);
    final w = (x(e.end) - x0 - 3).clamp(4.0, stripWidth);
    if (x0 >= stripWidth || x0 + w <= 0) return const [];
    final past = n != null && !e.end.isAfter(n);
    final hi = e.id == highlightId;
    final moved = !hi && ghosts.any((g) => g.eventId == e.id);
    final fits = _textWidth(e.title) <= w - 2 * _boxPadding;
    final narrow = w < 64 && !fits;
    final box = Positioned(
      left: x0,
      top: 30,
      width: w,
      height: 38,
      child: Opacity(
        opacity: past ? .38 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: _boxPadding),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: hi ? const Color(0x4DFFB36B) : (moved ? TimelineGhost.movedFill : const Color(0x21F2EEE6)),
            border: Border.all(color: hi ? Ink.hot : (moved ? Ink.cool : const Color(0x33F2EEE6))),
            borderRadius: BorderRadius.circular(8),
            boxShadow: hi ? const [BoxShadow(color: Color(0x80FFB36B), blurRadius: 28)] : null,
          ),
          child: narrow
              ? null
              : Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: _labelStyle),
        ),
      ),
    );
    final labelX = x0 + w + 8;
    final room = nextX.clamp(0.0, stripWidth) - labelX - 6;
    if (!narrow || room < minOutsideLabel) return [box];
    return [
      box,
      Positioned(
        left: labelX,
        top: 40,
        width: room,
        child: Opacity(
          opacity: past ? .38 : 1,
          child: Text(e.title,
              maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: _labelStyle.copyWith(color: Ink.dim)),
        ),
      ),
    ];
  }

  /// Where a label after the [i]th shown event must stop: the next event, or a ghost after it, whichever is first.
  double _labelLimit(CalendarEvent e, int i) {
    var limit = i + 1 < _shown.length ? x(_shown[i + 1].start) : stripWidth;
    for (final g in ghosts) {
      final gx = x(g.start);
      if (g.start.isAfter(e.start) && gx < limit) limit = gx;
    }
    return limit;
  }

  Widget _pin(Pin p) {
    return Positioned(
      left: x(p.at) - 6,
      top: 2,
      child: Opacity(
        opacity: p.done ? .45 : 1,
        child: SizedBox(
          width: 220,
          height: 72,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  color: Ink.cool,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Color(0x4086D8CC), spreadRadius: 4)],
                ),
              ),
              Positioned(left: 5.5, top: 14, child: CustomPaint(size: const Size(1, 56), painter: _DashPainter())),
              Positioned(
                left: 20,
                top: -3,
                child: Text(p.label, maxLines: 1, softWrap: false, style: ts(14, weight: FontWeight.w600, color: Ink.cool)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nowLine(double nx) {
    return Positioned(
      left: nx - 1,
      top: 4,
      child: SizedBox(
        width: 120,
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
            if (nx > 110)
              Positioned(
                right: 132, // the label sits to the left of the line
                top: -2,
                child: Text('BÂY GIỜ', style: ts(12, weight: FontWeight.w600, color: Ink.hot, spacing: 12 * .16)),
              ),
          ],
        ),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Ink.cool
      ..strokeWidth = 1;
    for (var y = 0.0; y < size.height; y += 8) {
      canvas.drawLine(Offset(0, y), Offset(0, (y + 4).clamp(0, size.height)), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => false;
}
