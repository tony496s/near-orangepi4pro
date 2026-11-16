import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/vi_format.dart';
import '../theme.dart';
import 'line_chart.dart';

/// The small gold tile in the middle of the day strip (the demo's `goldMini()`, scenario 3: "không xem nữa thì chart
/// thu về một góc"): eyebrow, today's price with its change since midnight, and a small area chart ending in a dot.
///
/// It takes the width it is given (the chart stretches or shrinks with it) and rises in when it first shows.
class GoldMini extends StatelessWidget {
  const GoldMini({super.key, required this.c});
  final AppController c;

  /// Width and chart height of the demo's tile.
  static const width = 300.0;
  static const chartHeight = 64.0;

  /// The demo's `.rise`: a 0.15 s wait, then 0.55 s of fade and a 14 px climb.
  static const riseFor = Duration(milliseconds: 700);
  static const _riseCurve = Interval(.15 / .7, 1, curve: Curves.ease);

  @override
  Widget build(BuildContext context) {
    final g = c.gold;
    final tile = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('VÀNG · USD/OUNCE', maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: eyebrow()),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(viNumber(g.last), key: const Key('gold-mini-price'), maxLines: 1, style: ts(34, height: 1.15)),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '${_signedPct(g.changePct)}%',
                key: const Key('gold-mini-change'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: ts(17, color: Ink.dim),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: chartHeight,
          width: double.infinity,
          child: LineChart(points: g.points),
        ),
      ],
    );
    return TweenAnimationBuilder<double>(
      key: const Key('gold-mini'),
      tween: Tween(begin: 0, end: 1),
      duration: riseFor,
      curve: _riseCurve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: tile,
    );
  }
}

/// "+0,64" / "-0,12": a percentage change with its sign and two Vietnamese decimals ("+0,00" when it rounds to 0).
String _signedPct(double v) {
  final digits = viNumber(v.abs(), decimals: 2);
  return '${v < 0 && digits != '0,00' ? '-' : '+'}$digits';
}
