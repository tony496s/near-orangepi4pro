import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/clock.dart';
import '../../core/vi_format.dart';
import '../theme.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

/// Tomorrow at a glance, reached by swiping up.
class TomorrowScreen extends StatelessWidget {
  const TomorrowScreen({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final day = dayOf(c.now).add(const Duration(days: 1));
    final events = c.plan.on(day);
    final first = c.plan.firstTomorrow(c.now);
    return Sky(
      kind: SkyKind.morning,
      glowX: first == null ? 740 : Timeline.x(first.start).clamp(0, stripWidth),
      child: Stack(
        children: [
          Positioned(
            left: 44,
            top: 34,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NGÀY MAI', style: eyebrow()),
                const SizedBox(height: 10),
                Text(shortDate(day), style: ts(60, weight: FontWeight.w600, height: 1.05)),
                const SizedBox(height: 10),
                Text('Vuốt xuống để về hôm nay', style: metaStyle()),
              ],
            ),
          ),
          Positioned(
            right: micZoneWidth,
            top: 30,
            width: 600,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(first == null ? 'NGÀY MAI TRỐNG LỊCH' : 'VIỆC ĐẦU TIÊN', style: eyebrow(color: Ink.cool)),
                const SizedBox(height: 8),
                Text(first?.title ?? 'Không có cuộc họp nào',
                    textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(46, weight: FontWeight.w600, height: 1.12)),
                const SizedBox(height: 10),
                if (first != null)
                  Text([('${hhmm(first.start)} – ${hhmm(first.end)}'), if (first.details.isNotEmpty) first.details].join(' · '),
                      style: metaStyle()),
              ],
            ),
          ),
          Positioned(left: 0, top: 212, child: Timeline(events: events, highlightId: first?.id)),
        ],
      ),
    );
  }
}
