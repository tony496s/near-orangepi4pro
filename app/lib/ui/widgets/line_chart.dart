import 'package:flutter/widgets.dart';

import '../../data/price_source.dart';
import '../theme.dart';

/// A price line: orange stroke, a soft fill fading down, a dot on the latest point. With [labels], faint grid lines
/// and the first and last time under the chart ([startLabel], [endLabel]).
class LineChart extends StatelessWidget {
  const LineChart({super.key, required this.points, this.labels = false, this.startLabel = '', this.endLabel = ''});

  final List<PricePoint> points;
  final bool labels;
  final String startLabel;
  final String endLabel;

  static const labelHeight = 18.0;

  @override
  Widget build(BuildContext context) {
    final chart = CustomPaint(
      painter: _LinePainter(points, grid: labels),
      size: Size.infinite,
    );
    if (!labels) return chart;
    final style = ts(12, color: Ink.faint, spacing: .5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: chart),
        SizedBox(
          height: labelHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(startLabel, style: style),
              Text(endLabel, style: style),
            ],
          ),
        ),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.points, {required this.grid});

  final List<PricePoint> points;
  final bool grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.isEmpty) return;
    var lo = points.first.price, hi = lo;
    for (final p in points) {
      if (p.price < lo) lo = p.price;
      if (p.price > hi) hi = p.price;
    }
    final pad = (hi - lo) * .12 + .5;
    lo -= pad;
    hi += pad;
    const dotR = 5.0;
    final w = size.width - dotR, h = size.height - dotR;
    Offset at(int i) => Offset(
      points.length == 1 ? w : i / (points.length - 1) * w,
      dotR + (1 - (points[i].price - lo) / (hi - lo)) * (h - dotR),
    );

    if (grid) {
      final gp = Paint()
        ..color = Ink.hair
        ..strokeWidth = 1;
      for (final f in const [.2, .5, .8]) {
        canvas.drawLine(Offset(0, size.height * f), Offset(size.width, size.height * f), gp);
      }
    }

    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    final last = at(points.length - 1);
    final fill = Path.from(line)
      ..lineTo(last.dx, size.height)
      ..lineTo(at(0).dx, size.height)
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

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.grid != grid ||
      old.points.length != points.length ||
      (points.isNotEmpty && old.points.isNotEmpty && old.points.last.price != points.last.price);
}
