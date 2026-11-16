import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/vi_format.dart';
import '../../data/price_source.dart';
import '../theme.dart';
import '../widgets/buttons.dart';
import '../widgets/line_chart.dart';
import '../widgets/sky.dart';

/// The gold price crossed the threshold (scenario 3, "tới ngưỡng thì báo một lần"; the demo's `goldAlert()`): on the
/// alert sky, when and which way it crossed, the price, the threshold and when it was set; the price since then
/// with the threshold line; "Xem chart" and "Tắt báo". Everything stays left of the mic and VI/EN strip (x 1360).
class GoldAlertScreen extends StatelessWidget {
  const GoldAlertScreen({super.key, required this.c, required this.alert});
  final AppController c;
  final GoldCrossedAlert alert;

  static const textLeft = 48.0;
  static const textTop = 42.0;
  static const textWidth = 440.0;

  /// The chart (the demo's `.ga-chart`), with the buttons after it on the same band; both end at the mic strip.
  static const chartLeft = 520.0;
  static const chartTop = 34.0;
  static const chartHeight = 200.0;
  static const buttonsTop = 32.0; // under the chart's top: y 66, as the demo's `.btns`
  static const buttonsGap = 48.0;

  @override
  Widget build(BuildContext context) {
    final rule = alert.rule;
    final points = chartPoints(c.gold.points, rule.setAt);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${rule.above ? 'VÀNG VƯỢT NGƯỠNG' : 'VÀNG XUỐNG DƯỚI NGƯỠNG'} · ${hhmm(alert.shownAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: eyebrow(color: Ink.ink),
        ),
        const SizedBox(height: 10),
        Text(
          viNumber(alert.price),
          key: const Key('gold-alert-price'),
          maxLines: 1,
          softWrap: false,
          style: ts(66, weight: FontWeight.w600, height: 1.05),
        ),
        const SizedBox(height: 10),
        Text(
          'Mốc ${viPrice(rule.threshold)} anh đặt lúc ${hhmm(rule.setAt)} · số liệu mẫu',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: metaStyle(),
        ),
      ],
    );
    return Sky(
      key: const Key('gold-alert-screen'),
      kind: SkyKind.alert,
      glowX: 740,
      child: Stack(
        children: [
          Positioned(left: textLeft, top: textTop, width: textWidth, child: text),
          Positioned(
            left: chartLeft,
            right: micZoneWidth,
            top: chartTop,
            height: chartHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _ThresholdChart(points: points, threshold: rule.threshold, above: rule.above),
                ),
                const SizedBox(width: buttonsGap),
                Padding(
                  padding: const EdgeInsets.only(top: buttonsTop),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Pill(
                        'Xem chart',
                        key: const Key('alert-primary'),
                        style: PillStyle.ink,
                        onTap: () => c.alertAction(AlertAction.primary),
                      ),
                      const SizedBox(width: 16),
                      Pill(
                        'Tắt báo',
                        key: const Key('alert-secondary'),
                        onTap: () => c.alertAction(AlertAction.secondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Today's [day] from the price when the alert was set (the step at or just before [setAt], as the demo starts at
  /// 08:10 for an alert set at 08:13) to now; the whole day when that leaves fewer than 2 points (set on another day,
  /// or within the latest step).
  static List<PricePoint> chartPoints(List<PricePoint> day, DateTime setAt) {
    final from = day.lastIndexWhere((p) => !p.at.isAfter(setAt));
    final since = from <= 0 ? day : day.sublist(from);
    return since.length < 2 ? day : since;
  }
}

/// The price since the alert was set, with the dashed threshold and its price at the left end of the line (the
/// right end is where the price crosses it, under the latest-price dot): above the line when the price came up to
/// it, under it when the price came down, so the label sits on the side the line has not been.
class _ThresholdChart extends StatelessWidget {
  const _ThresholdChart({required this.points, required this.threshold, required this.above});

  final List<PricePoint> points;
  final double threshold;
  final bool above;

  static const _labelGap = 3.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final y = thresholdY(points, threshold, box.maxHeight - LineChart.labelHeight);
        final label = Text(
          viPrice(threshold),
          key: const Key('gold-alert-threshold'),
          maxLines: 1,
          softWrap: false,
          style: ts(14, weight: FontWeight.w600, color: Ink.cool),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: LineChart(
                points: points,
                labels: true,
                startLabel: hhmm(points.first.at),
                endLabel: hhmm(points.last.at),
                threshold: threshold,
              ),
            ),
            if (above)
              Positioned(left: 8, bottom: box.maxHeight - y + _labelGap, child: label)
            else
              Positioned(left: 8, top: y + _labelGap, child: label),
          ],
        );
      },
    );
  }

  /// The y of [threshold] in a plot [height] tall, as [LineChart] draws it: the range of the points and the threshold,
  /// padded by 12% + 0.5 on each side, inside the 5 px dot radius at the top and bottom.
  static double thresholdY(List<PricePoint> points, double threshold, double height) {
    var lo = threshold, hi = threshold;
    for (final p in points) {
      if (p.price < lo) lo = p.price;
      if (p.price > hi) hi = p.price;
    }
    final pad = (hi - lo) * .12 + .5;
    lo -= pad;
    hi += pad;
    const dotR = 5.0;
    return dotR + (1 - (threshold - lo) / (hi - lo)) * (height - 2 * dotR);
  }
}
