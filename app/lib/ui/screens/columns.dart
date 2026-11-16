import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/presenter.dart';
import '../../core/vi_format.dart';
import '../../domain/intent/commands.dart';
import '../../domain/strip_layout.dart';
import '../theme.dart';
import '../widgets/line_chart.dart';
import '../widgets/sky.dart';

/// The split home screen (scenario 5 of near-demo.html): one panel per column of [AppController.layout], across
/// x 0..[columnsRight]. The strip right of that, under the mic and the VI/EN switch, stays empty.
///
/// Touch: hold a column to zoom it (the others shrink to an edge that still shows the time, price or countdown); tap
/// to zoom back. A tap on the gold column opens the full chart. Talking is by the mic button only here: the strip's
/// own long press is off on this screen.
class ColumnsScreen extends StatefulWidget {
  const ColumnsScreen({super.key, required this.c});
  final AppController c;

  static const columnsRight = stripWidth - micZoneWidth;

  /// Width of a column shrunk next to a zoomed one.
  static const edgeWidth = 132.0;

  @override
  State<ColumnsScreen> createState() => _ColumnsScreenState();
}

class _ColumnsScreenState extends State<ColumnsScreen> {
  int? _zoomed;

  AppController get c => widget.c;

  void _hold(int i) {
    c.touched();
    setState(() => _zoomed = _zoomed == i ? null : i);
  }

  void _tap(int i, Panel p) {
    c.touched();
    if (_zoomed != null) {
      setState(() => _zoomed = null);
    } else if (p == Panel.gold) {
      c.run(const ShowGold());
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final panels = c.layout.panels;
    final zoomed = _zoomed != null && _zoomed! < panels.length ? _zoomed : null;
    final children = <Widget>[];
    for (var i = 0; i < panels.length; i++) {
      if (i > 0) children.add(Container(width: 1, margin: const EdgeInsets.symmetric(vertical: 28), color: Ink.hair));
      final p = panels[i];
      final body = GestureDetector(
        key: Key('column-touch-${p.name}'),
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _hold(i),
        onTap: () => _tap(i, p),
        child: zoomed == null || zoomed == i ? _panel(p) : _edge(p),
      );
      children.add(zoomed == null || zoomed == i
          ? Expanded(child: body)
          : SizedBox(width: ColumnsScreen.edgeWidth, child: body));
    }
    return Sky(
      kind: SkyKind.at(now),
      glowX: ColumnsScreen.columnsRight / 2,
      child: Padding(
        padding: const EdgeInsets.only(right: micZoneWidth),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }

  Widget _panel(Panel p) => switch (p) {
        Panel.calendar => CalendarPanel(key: const Key('column-calendar'), c: c),
        Panel.gold => GoldPanel(key: const Key('column-gold'), c: c),
        Panel.timer => TimerPanel(key: const Key('column-timer'), c: c),
      };

  /// A shrunk column: one glanceable value.
  Widget _edge(Panel p) {
    final now = c.now;
    final timer = c.timer;
    final (label, value) = switch (p) {
      Panel.calendar => ('GIỜ', c.clockValid ? hhmm(now) : '--:--'),
      Panel.gold => ('VÀNG', viNumber(c.gold.last, decimals: 0)),
      Panel.timer => (
          timer != null && timer.focus ? 'TẬP TRUNG' : 'HẸN GIỜ',
          timer == null || timer.isDone(now) ? '—' : mmss(timer.remaining(now))
        ),
    };
    return Center(
      key: Key('column-edge-${p.name}'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: eyebrow(color: p == Panel.gold ? Ink.hot : Ink.cool)),
          const SizedBox(height: 8),
          Text(value, style: ts(28, weight: FontWeight.w400)),
        ],
      ),
    );
  }
}

const _pad = EdgeInsets.fromLTRB(40, 26, 32, 24);

/// Today: clock, what is next (or the latest answer), and the two events after it.
class CalendarPanel extends StatelessWidget {
  const CalendarPanel({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final valid = c.clockValid;
    final block = stripBlock(c);
    final next = c.plan.next(now);
    final later = next == null
        ? const <String>[]
        : [
            for (final e in c.plan.remainingToday(now).where((e) => e.start.isAfter(next.start)).take(2))
              '${hhmm(e.start)} ${e.title}',
          ];
    return Padding(
      padding: _pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(valid ? 'HÔM NAY · ${shortDate(now).toUpperCase()}' : 'HÔM NAY', style: eyebrow(color: Ink.dim)),
          Text(
            valid ? hhmm(now) : '--:--',
            key: const Key('columns-clock'),
            style: ts(84, weight: FontWeight.w300, spacing: -2, height: 1.05),
          ),
          const SizedBox(height: 6),
          Text(block.eyebrow, style: eyebrow(color: block.cool ? Ink.cool : Ink.hot)),
          const SizedBox(height: 2),
          Text(
            block.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts(30, weight: FontWeight.w600, height: 1.15),
          ),
          Text(block.meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(17)),
          const Spacer(),
          if (later.isNotEmpty)
            Text('Sau đó: ${later.join(' · ')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(15)),
        ],
      ),
    );
  }
}

/// World gold today: price, change since midnight, a small chart.
class GoldPanel extends StatelessWidget {
  const GoldPanel({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final g = c.gold;
    final up = g.change >= 0;
    final sign = up ? '+' : '-';
    final change = '$sign${viNumber(g.change.abs())} ($sign${viNumber(g.changePct.abs(), decimals: 2)}%) hôm nay';
    return Padding(
      padding: _pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('VÀNG · USD/OUNCE', style: eyebrow()),
              const Spacer(),
              Text('Số liệu mẫu', style: ts(12, color: Ink.faint)),
            ],
          ),
          Text(
            viNumber(g.last),
            key: const Key('gold-price'),
            style: ts(56, weight: FontWeight.w300, spacing: -1, height: 1.1),
          ),
          Text(change, style: ts(16, color: up ? Ink.cool : Ink.hot)),
          const SizedBox(height: 10),
          Expanded(
            child: LineChart(points: g.points, labels: true, startLabel: '00:00', endLabel: hhmm(now)),
          ),
        ],
      ),
    );
  }
}

/// The running timer as a ring, or an idle ring with how to start one.
class TimerPanel extends StatelessWidget {
  const TimerPanel({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final t = c.timer;
    final running = t != null && !t.isDone(now);
    return Padding(
      padding: _pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(running && t.focus ? 'TẬP TRUNG' : 'HẸN GIỜ', style: eyebrow(color: Ink.cool)),
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: CustomPaint(
                  painter: _RingPainter(running ? t.progress(now) : 0),
                  child: Center(
                    child: running
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(mmss(t.remaining(now)), style: ts(40, weight: FontWeight.w300, height: 1.1)),
                              Text('Kết thúc ${hhmm(t.endsAt)}', style: metaStyle(14)),
                            ],
                          )
                        : Text('Chưa chạy', style: metaStyle(17)),
                  ),
                ),
              ),
            ),
          ),
          if (!running)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Nói “hẹn giờ … phút”', style: metaStyle(15)),
              ),
            ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 7.0;
    final r = math.min(size.width, size.height) / 2 - stroke;
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Ink.hair
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0, 1),
        false,
        Paint()
          ..color = Ink.cool
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}
