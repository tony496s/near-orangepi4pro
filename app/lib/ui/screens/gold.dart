import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/vi_format.dart';
import '../../data/price_source.dart';
import '../theme.dart';
import '../widgets/line_chart.dart';

/// The full gold chart (scenario 3 of near-demo.html): price, change since midnight, high and low on the left; the
/// day's line on the right, with yesterday's line ("so với hôm qua") and the alert threshold when set. Drag or tap on
/// the chart to read any point. Everything stays left of the mic and VI/EN strip (x 1360).
class GoldScreen extends StatelessWidget {
  const GoldScreen({super.key, required this.c});
  final AppController c;

  /// Left edge of the chart and its right edge (clear of the mic and VI/EN strip).
  static const chartLeft = 420.0;
  static const chartRight = stripWidth - micZoneWidth - 20;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final g = c.gold;
    final alert = c.goldAlert;
    final threshold = alert != null && !alert.fired ? alert.threshold : null;
    List<PricePoint>? compare;
    PricePoint? yesterdayNow;
    if (c.goldCompare) {
      final y = c.goldYesterday.points;
      compare = upToTimeOfDay(y, g.points.last.at);
      yesterdayNow = compare.isEmpty ? null : compare.last;
    }
    final up = g.change >= 0;
    return DecoratedBox(
      key: const Key('gold-screen'),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B1A2C), Color(0xFF14304A)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 40,
            top: 28,
            width: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('VÀNG THẾ GIỚI · USD/OUNCE', style: eyebrow()),
                const SizedBox(height: 6),
                Text(
                  viNumber(g.last),
                  key: const Key('gold-full-price'),
                  style: ts(72, weight: FontWeight.w300, spacing: -2, height: 1.05),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_signed(g.change)} (${_signed(g.changePct, decimals: 2)}%) từ 0 giờ',
                  style: ts(18, weight: FontWeight.w500, color: up ? Ink.cool : Ink.hot),
                ),
                const SizedBox(height: 6),
                Text('Cao ${viNumber(g.high)} · Thấp ${viNumber(g.low)}', style: metaStyle(16)),
              ],
            ),
          ),
          Positioned(
            left: 40,
            bottom: 22,
            width: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (yesterdayNow != null)
                  Text(
                    'Hôm qua lúc này: ${viNumber(yesterdayNow.price)} · chênh ${_signed(g.last - yesterdayNow.price)}',
                    style: ts(16, weight: FontWeight.w500, color: Ink.dim),
                  ),
                if (threshold != null) ...[
                  Text(
                    '${alert!.above ? 'Báo khi vượt' : 'Báo khi xuống dưới'} ${viPrice(threshold)}',
                    style: ts(16, weight: FontWeight.w600, color: Ink.cool),
                  ),
                  Text('Còn cách ${viNumber((threshold - g.last).abs())} đô', style: metaStyle(14)),
                ],
                const SizedBox(height: 4),
                Text('Số liệu mẫu', style: ts(12, color: Ink.faint)),
              ],
            ),
          ),
          Positioned(
            left: chartLeft,
            top: 36,
            width: chartRight - chartLeft,
            bottom: 14,
            child: _ScrubChart(
              c: c,
              points: g.points,
              compare: compare,
              threshold: threshold,
              thresholdLabel: threshold == null ? '' : 'Báo khi vượt ${viPrice(threshold)}',
              endLabel: hhmm(now),
            ),
          ),
        ],
      ),
    );
  }

  /// [day]'s points up to the time of day of [t] (yesterday's line, cut where today's ends).
  static List<PricePoint> upToTimeOfDay(List<PricePoint> day, DateTime t) {
    int minutes(DateTime d) => d.hour * 60 + d.minute;
    return [
      for (final p in day)
        if (minutes(p.at) <= minutes(t)) p,
    ];
  }
}

/// "+26,5" / "-3,1": always a sign, Vietnamese decimals.
String _signed(double v, {int decimals = 1}) => '${v < 0 ? '-' : '+'}${viNumber(v.abs(), decimals: decimals)}';

class _ScrubChart extends StatefulWidget {
  const _ScrubChart({
    required this.c,
    required this.points,
    required this.compare,
    required this.threshold,
    required this.thresholdLabel,
    required this.endLabel,
  });

  final AppController c;
  final List<PricePoint> points;
  final List<PricePoint>? compare;
  final double? threshold;
  final String thresholdLabel;
  final String endLabel;

  @override
  State<_ScrubChart> createState() => _ScrubChartState();
}

class _ScrubChartState extends State<_ScrubChart> {
  int? _selected;

  void _pick(Offset local, double width) {
    widget.c.touched();
    setState(() => _selected = LineChart.indexAt(local.dx, widget.points.length, width, yLabels: true));
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    final mid = points[points.length ~/ 2].at;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        final sel = _selected != null && _selected! < points.length ? _selected : null;
        return GestureDetector(
          key: const Key('gold-chart'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _pick(d.localPosition, width),
          onHorizontalDragStart: (d) => _pick(d.localPosition, width),
          onHorizontalDragUpdate: (d) => _pick(d.localPosition, width),
          child: Stack(
            children: [
              Positioned.fill(
                child: LineChart(
                  points: points,
                  labels: true,
                  startLabel: hhmm(points.first.at),
                  midLabel: points.length > 2 ? hhmm(mid) : '',
                  endLabel: widget.endLabel,
                  compare: widget.compare,
                  threshold: widget.threshold,
                  thresholdLabel: widget.thresholdLabel,
                  yLabels: true,
                  selected: sel,
                ),
              ),
              if (sel != null)
                Positioned(
                  top: 0,
                  left: (LineChart.xOf(sel, points.length, width, yLabels: true) - 80).clamp(
                    0,
                    width - LineChart.axisWidth - 160,
                  ),
                  width: 160,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0xCC0B1A2C), borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        '${hhmm(points[sel].at)} · ${viNumber(points[sel].price)}',
                        key: const Key('gold-scrub-label'),
                        style: ts(15, weight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
