import 'package:flutter/widgets.dart';

import '../../app/presenter.dart';
import '../../core/vi_format.dart';
import '../../domain/models.dart';
import '../theme.dart';

/// The day from 07:00 to 21:00 across the full width: hour marks, events, reminder pins and a "now" line.
class Timeline extends StatelessWidget {
  const Timeline({super.key, required this.events, this.now, this.pins = const [], this.highlightId});

  static const startHour = 7;
  static const endHour = 21;
  static const pxPerHour = stripWidth / (endHour - startHour);
  static const height = 108.0;

  final List<CalendarEvent> events;

  /// Null for a day that is not today (no "now" line, nothing dimmed).
  final DateTime? now;
  final List<Pin> pins;
  final String? highlightId;

  static double x(DateTime t) => ((t.hour + t.minute / 60 + t.second / 3600) - startHour) * pxPerHour;

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
          for (final e in events) ..._event(e, n),
          for (final p in pins) _pin(p),
          if (nx != null) _nowLine(nx),
        ],
      ),
    );
  }

  List<Widget> _event(CalendarEvent e, DateTime? n) {
    final x0 = x(e.start);
    final w = (x(e.end) - x0 - 3).clamp(4.0, stripWidth);
    if (x0 >= stripWidth || x0 + w <= 0 || e.kind == EventKind.deadline) return const [];
    final past = n != null && !e.end.isAfter(n);
    final hi = e.id == highlightId;
    final narrow = w < 64;
    final box = Positioned(
      left: x0,
      top: 30,
      width: w,
      height: 38,
      child: Opacity(
        opacity: past ? .38 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: hi ? const Color(0x4DFFB36B) : const Color(0x21F2EEE6),
            border: Border.all(color: hi ? Ink.hot : const Color(0x33F2EEE6)),
            borderRadius: BorderRadius.circular(8),
            boxShadow: hi ? const [BoxShadow(color: Color(0x80FFB36B), blurRadius: 28)] : null,
          ),
          child: narrow
              ? null
              : Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: ts(14, weight: FontWeight.w500)),
        ),
      ),
    );
    if (!narrow) return [box];
    return [
      box,
      Positioned(
        left: x0 + w + 8,
        top: 40,
        child: Opacity(
          opacity: past ? .38 : 1,
          child: Text(e.title, maxLines: 1, softWrap: false, style: ts(14, weight: FontWeight.w500, color: Ink.dim)),
        ),
      ),
    ];
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
