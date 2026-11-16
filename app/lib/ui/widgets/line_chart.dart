import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../../data/price_source.dart';
import '../theme.dart';

/// A price line: orange stroke, a soft fill fading down, a dot on the latest point. With [labels], faint grid lines
/// and the first, middle and last time under the chart ([startLabel], [midLabel], [endLabel]).
///
/// The full gold chart adds:
/// - [compare]: yesterday's line, drawn dim and dashed on the same y scale;
/// - [threshold]: a dashed cool line with [thresholdLabel] at its right end;
/// - [yLabels]: three prices on a right-hand axis;
/// - [selected]: the scrubbed point, with a vertical line and a dot.
///
/// The USD/VND chart uses:
/// - [xTicks]: labels under chosen points (days 0/10/20/30) instead of start, middle and end;
/// - [yTicks]: grid lines (and, with [yLabels], prices) at round values instead of three fixed heights.
class LineChart extends StatelessWidget {
  const LineChart({
    super.key,
    required this.points,
    this.labels = false,
    this.startLabel = '',
    this.midLabel = '',
    this.endLabel = '',
    this.compare,
    this.threshold,
    this.thresholdLabel = '',
    this.yLabels = false,
    this.selected,
    this.xTicks,
    this.yTicks,
  });

  final List<PricePoint> points;
  final bool labels;
  final String startLabel;
  final String midLabel;
  final String endLabel;
  final List<PricePoint>? compare;
  final double? threshold;
  final String thresholdLabel;
  final bool yLabels;
  final int? selected;

  /// With [labels]: (point index, text) pairs shown under those points, in place of [startLabel], [midLabel] and
  /// [endLabel]. The first point's label starts at its x, the last point's ends at its x, others are centred on it.
  final List<(int, String)>? xTicks;

  /// With [labels]: prices for the grid lines (and the right-hand axis with [yLabels]), in place of the three fixed
  /// lines. The y range grows to include them, so pass values near the data (see [niceTicks]).
  final List<double>? yTicks;

  static const labelHeight = 18.0;

  /// Width kept on the right for the price axis when [yLabels] is on.
  static const axisWidth = 56.0;

  static const _dotR = 5.0;

  /// The x of point [i] of [count] in a chart [width] wide (the same mapping the painter uses).
  static double xOf(int i, int count, double width, {bool yLabels = false}) {
    final w = width - (yLabels ? axisWidth : 0) - _dotR;
    return count <= 1 ? w : i / (count - 1) * w;
  }

  /// The point nearest to [dx] in a chart [width] wide, for scrubbing.
  static int indexAt(double dx, int count, double width, {bool yLabels = false}) {
    if (count <= 1) return 0;
    final w = width - (yLabels ? axisWidth : 0) - _dotR;
    return (dx / w * (count - 1)).round().clamp(0, count - 1);
  }

  /// Round values from [lo] to [hi] for [yTicks]: multiples of a step of 1, 2 or 5 times a power of ten, about
  /// [count] steps across the range. When that leaves fewer than `count - 1` values (at least one), the next smaller
  /// round step is used instead. Empty when [hi] is not above [lo].
  static List<double> niceTicks(double lo, double hi, int count) {
    if (!(hi > lo) || count < 1) return const [];
    const ladder = [1, 2, 5, 10];
    final raw = (hi - lo) / count;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final found = ladder.indexWhere((m) => m * mag >= raw);
    final i = found < 0 ? ladder.length - 1 : found; // log rounding: raw can land a hair above 10 * mag
    List<double> every(double step) => [for (var k = (lo / step).ceil(); k * step <= hi + step * 1e-9; k++) k * step];
    final ticks = every(ladder[i] * mag);
    if (ticks.length >= math.max(1, count - 1)) return ticks;
    // The first round step above raw can leave only one or two values in the range: take the next smaller one.
    return every(i > 0 ? ladder[i - 1] * mag : mag / 2);
  }

  @override
  Widget build(BuildContext context) {
    final chart = CustomPaint(
      painter: _LinePainter(
        points,
        grid: labels,
        compare: compare,
        threshold: threshold,
        thresholdLabel: thresholdLabel,
        yLabels: yLabels,
        selected: selected,
        yTicks: yTicks,
      ),
      size: Size.infinite,
    );
    if (!labels) return chart;
    final style = ts(12, color: Ink.faint, spacing: .5);
    final ticks = xTicks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: chart),
        SizedBox(
          height: labelHeight,
          child: ticks != null
              ? _ticksUnder(ticks, style)
              : Padding(
                  padding: EdgeInsets.only(right: yLabels ? axisWidth : 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(startLabel, style: style),
                      if (midLabel.isNotEmpty) Text(midLabel, style: style),
                      Text(endLabel, style: style),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _ticksUnder(List<(int, String)> ticks, TextStyle style) => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth;
      final n = points.length;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          for (final (i, text) in ticks)
            if (i >= 0 && i < n)
              switch (xOf(i, n, width, yLabels: yLabels)) {
                final x when i == 0 => Positioned(
                  left: x,
                  bottom: 0,
                  child: Text(text, style: style),
                ),
                final x when i == n - 1 => Positioned(
                  right: width - x,
                  bottom: 0,
                  child: Text(text, style: style),
                ),
                final x => Positioned(
                  left: x,
                  bottom: 0,
                  child: FractionalTranslation(
                    translation: const Offset(-.5, 0),
                    child: Text(text, style: style),
                  ),
                ),
              },
        ],
      );
    },
  );
}

class _LinePainter extends CustomPainter {
  _LinePainter(
    this.points, {
    required this.grid,
    this.compare,
    this.threshold,
    this.thresholdLabel = '',
    this.yLabels = false,
    this.selected,
    this.yTicks,
  });

  final List<PricePoint> points;
  final bool grid;
  final List<PricePoint>? compare;
  final double? threshold;
  final String thresholdLabel;
  final bool yLabels;
  final int? selected;
  final List<double>? yTicks;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.isEmpty) return;
    var lo = points.first.price, hi = lo;
    void widen(double v) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }

    for (final p in points) {
      widen(p.price);
    }
    for (final p in compare ?? const <PricePoint>[]) {
      widen(p.price);
    }
    if (threshold != null) widen(threshold!);
    for (final v in yTicks ?? const <double>[]) {
      widen(v);
    }
    final pad = (hi - lo) * .12 + .5;
    lo -= pad;
    hi += pad;
    const dotR = LineChart._dotR;
    final plotW = size.width - (yLabels ? LineChart.axisWidth : 0);
    final h = size.height - dotR;
    double yOf(double price) => dotR + (1 - (price - lo) / (hi - lo)) * (h - dotR);
    Offset at(List<PricePoint> s, int i, int count) =>
        Offset(LineChart.xOf(i, count, size.width, yLabels: yLabels), yOf(s[i].price));

    final ticks = yTicks;
    if (grid && ticks != null) {
      final gp = Paint()
        ..color = Ink.hair
        ..strokeWidth = 1;
      for (final v in ticks) {
        final y = yOf(v);
        canvas.drawLine(Offset(0, y), Offset(plotW, y), gp);
        if (yLabels) _text(canvas, _axis(v), Offset(plotW + 8, y - 8), ts(12, color: Ink.faint));
      }
    } else if (grid) {
      final gp = Paint()
        ..color = Ink.hair
        ..strokeWidth = 1;
      for (final f in const [.2, .5, .8]) {
        final y = size.height * f;
        canvas.drawLine(Offset(0, y), Offset(plotW, y), gp);
        if (yLabels) {
          final price = lo + (1 - (y - dotR) / (h - dotR)) * (hi - lo);
          _text(canvas, _axis(price), Offset(plotW + 8, y - 8), ts(12, color: Ink.faint));
        }
      }
    }

    // Yesterday: same time axis (index = 5-minute step since midnight), dim and dashed.
    final cmp = compare;
    if (cmp != null && cmp.length > 1) {
      final count = points.length > cmp.length ? points.length : cmp.length;
      final path = Path()..moveTo(at(cmp, 0, count).dx, at(cmp, 0, count).dy);
      for (var i = 1; i < cmp.length; i++) {
        path.lineTo(at(cmp, i, count).dx, at(cmp, i, count).dy);
      }
      _dashed(
        canvas,
        path,
        Paint()
          ..color = Ink.dim
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    final n = points.length;
    final line = Path()..moveTo(at(points, 0, n).dx, at(points, 0, n).dy);
    for (var i = 1; i < n; i++) {
      line.lineTo(at(points, i, n).dx, at(points, i, n).dy);
    }
    final last = at(points, n - 1, n);
    final fill = Path.from(line)
      ..lineTo(last.dx, size.height)
      ..lineTo(at(points, 0, n).dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Ink.hot.withValues(alpha: .28), Ink.hot.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = Ink.hot
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );

    final thr = threshold;
    if (thr != null) {
      final y = yOf(thr);
      final p = Path()
        ..moveTo(0, y)
        ..lineTo(plotW, y);
      _dashed(
        canvas,
        p,
        Paint()
          ..color = Ink.cool
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      if (thresholdLabel.isNotEmpty) {
        final style = ts(13, weight: FontWeight.w600, color: Ink.cool);
        final tp = TextPainter(
          text: TextSpan(text: thresholdLabel, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(plotW - tp.width - 4, y - tp.height - 3));
      }
    }

    final sel = selected;
    if (sel != null && sel >= 0 && sel < n) {
      final p = at(points, sel, n);
      canvas.drawLine(
        Offset(p.dx, 0),
        Offset(p.dx, size.height),
        Paint()
          ..color = Ink.faint
          ..strokeWidth = 1,
      );
      canvas.drawCircle(p, dotR, Paint()..color = Ink.ink);
    }

    canvas.drawCircle(last, dotR, Paint()..color = Ink.hot);
    canvas.drawCircle(
      last,
      dotR + 2,
      Paint()
        ..color = Ink.hot.withValues(alpha: .35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  static String _axis(double v) {
    final s = v.round().toString();
    return s.length > 3 ? '${s.substring(0, s.length - 3)}.${s.substring(s.length - 3)}' : s;
  }

  static void _text(Canvas canvas, String text, Offset at, TextStyle style) {
    (TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout()).paint(canvas, at);
  }

  static void _dashed(Canvas canvas, Path path, Paint paint, {double dash = 6, double gap = 5}) {
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += dash + gap) {
        canvas.drawPath(m.extractPath(d, (d + dash).clamp(0, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.grid != grid ||
      old.yLabels != yLabels ||
      old.selected != selected ||
      old.threshold != threshold ||
      old.thresholdLabel != thresholdLabel ||
      old.compare?.length != compare?.length ||
      !listEquals(old.yTicks, yTicks) ||
      old.points.length != points.length ||
      (points.isNotEmpty && old.points.isNotEmpty && old.points.last.price != points.last.price);
}
