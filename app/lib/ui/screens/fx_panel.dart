import 'package:flutter/widgets.dart';

import '../../core/vi_format.dart';
import '../../data/fx_source.dart';
import '../../data/price_source.dart';
import '../theme.dart';
import '../widgets/line_chart.dart';

/// The same padding as the other home columns (columns.dart).
const _pad = EdgeInsets.fromLTRB(40, 26, 32, 24);

/// "16/11"
String _ddmm(DateTime d) => '${two(d.day)}/${two(d.month)}';

/// "+12" / "-5": always a sign, whole đồng. The sign follows the rounded value, so a tiny drop is "+0", not "-0".
String _signed(double v) {
  final r = v.round();
  return '${r < 0 ? '-' : '+'}${viNumber(r.abs().toDouble(), decimals: 0)}';
}

/// Up (or flat) is cool, down is hot, like the gold column.
Color _tone(double change) => change.round() >= 0 ? Ink.cool : Ink.hot;

/// The dollar column of the home screen (scenario 5 of near-demo.html, "đổi cột giữa sang tỷ giá đô la"): today's sell
/// rate, the change since yesterday and the 30 days as a small chart. A sibling of `GoldPanel`, meant for a column
/// 400-480 px wide and 320 tall (one of three columns left of the mic strip).
class FxPanel extends StatelessWidget {
  const FxPanel({super.key, required this.series});

  /// One point per day, ending today ([FxSource.usdVnd]).
  final PriceSeries series;

  @override
  Widget build(BuildContext context) {
    final s = series;
    final change = s.sinceYesterday;
    return Padding(
      padding: _pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('ĐÔ LA MỸ · USD/VND', maxLines: 1, overflow: TextOverflow.ellipsis, style: eyebrow()),
              ),
              const SizedBox(width: 12),
              Text('Số liệu mẫu', style: ts(12, color: Ink.faint)),
            ],
          ),
          Text(
            viNumber(s.last, decimals: 0),
            key: const Key('fx-price'),
            style: ts(56, weight: FontWeight.w300, spacing: -1, height: 1.1),
          ),
          Text(
            '${_signed(change)} so với hôm qua · bán ra',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts(16, color: _tone(change)),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LineChart(
              points: s.points,
              labels: true,
              startLabel: _ddmm(s.points.first.at),
              endLabel: _ddmm(s.points.last.at),
            ),
          ),
        ],
      ),
    );
  }
}

/// The dollar column zoomed (held) on the home screen: the rate, its change since yesterday and over the 30 days, the
/// highest rate, and the chart with round rates on a right-hand axis and dates under days 0/10/20/30. Meant for about
/// 1000 px wide (960-1100) and 320 tall.
class FxZoom extends StatelessWidget {
  const FxZoom({super.key, required this.series});

  /// One point per day, ending today ([FxSource.usdVnd]).
  final PriceSeries series;

  /// Rates for the right-hand axis: round values over the data padded by 15% (at least 2 đồng) on each side.
  static List<double> yTicksFor(PriceSeries s) {
    final pad = (s.high - s.low) * .15;
    final p = pad < 2 ? 2.0 : pad;
    return LineChart.niceTicks(s.low - p, s.high + p, 4);
  }

  /// The points labelled under the chart: the first, the last and two evenly between (days 0/10/20/30 of 31).
  static List<int> xTickIndices(int count) => {for (var k = 0; k <= 3; k++) ((count - 1) * k / 3).round()}.toList();

  @override
  Widget build(BuildContext context) {
    final s = series;
    final pts = s.points;
    final days = pts.length - 1;
    final change = s.sinceYesterday;
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 26, 34, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'ĐÔ LA MỸ · USD/VND · BÁN RA · $days NGÀY',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: eyebrow(),
                ),
              ),
              const SizedBox(width: 12),
              Text('Số liệu mẫu', style: ts(12, color: Ink.faint)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                viNumber(s.last, decimals: 0),
                key: const Key('fx-zoom-price'),
                style: ts(40, weight: FontWeight.w300, spacing: -1, height: 1.15),
              ),
              const SizedBox(width: 18),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${_signed(change)} so với hôm qua',
                        style: TextStyle(color: _tone(change)),
                      ),
                      TextSpan(
                        text: ' · ${_signed(s.change)} trong $days ngày · cao nhất ${viNumber(s.high, decimals: 0)}',
                      ),
                    ],
                  ),
                  key: const Key('fx-zoom-change'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(17, color: Ink.dim),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LineChart(
              points: pts,
              labels: true,
              yLabels: true,
              yTicks: yTicksFor(s),
              xTicks: [for (final i in xTickIndices(pts.length)) (i, _ddmm(pts[i].at))],
            ),
          ),
        ],
      ),
    );
  }
}

/// The dollar column shrunk next to a zoomed one: the label, the rate and the change since yesterday, centred. Meant
/// for 130-230 px wide and 320 tall (the home screen's edge is 132).
class FxRail extends StatelessWidget {
  const FxRail({super.key, required this.series});

  /// One point per day, ending today ([FxSource.usdVnd]).
  final PriceSeries series;

  @override
  Widget build(BuildContext context) {
    final s = series;
    final change = s.sinceYesterday;
    // Top-left like the other rails of the columns; scale down rather than overflow if a value is wider than the rail.
    Widget fit(Widget child) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: child);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          fit(Text('USD/VND', style: eyebrow())),
          const SizedBox(height: 8),
          fit(
            Text(
              viNumber(s.last, decimals: 0),
              key: const Key('fx-rail-price'),
              style: ts(34, weight: FontWeight.w300, spacing: -1, height: 1.1),
            ),
          ),
          const SizedBox(height: 4),
          fit(Text('${_signed(change)} hôm qua', style: ts(16, color: _tone(change)))),
        ],
      ),
    );
  }
}
