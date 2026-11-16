import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/presenter.dart';
import '../../core/vi_format.dart';
import '../theme.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

/// End of the day: meetings, focus time, quick notes, and what is still open (tap to tick off).
class RecapScreen extends StatelessWidget {
  const RecapScreen({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final r = recapOf(c);
    return Sky(
      kind: SkyKind.evening,
      glowX: Timeline.x(now).clamp(0, stripWidth),
      child: Stack(
        children: [
          Positioned(
            left: 44,
            top: 30,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TỔNG KẾT HÔM NAY', style: eyebrow()),
                const SizedBox(height: 12),
                Text(hhmm(now), style: ts(84, weight: FontWeight.w300, spacing: -2, height: 1)),
                const SizedBox(height: 10),
                Text(shortDate(now), style: metaStyle()),
              ],
            ),
          ),
          Positioned(
            left: 400,
            top: 44,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Stat('${r.meetings}', 'cuộc họp'),
                const SizedBox(width: 46),
                _Stat('${r.focusMinutes}', 'phút tập trung · ${r.sessions} phiên'),
                const SizedBox(width: 46),
                _Stat('${r.notes}', 'ghi nhanh'),
              ],
            ),
          ),
          Positioned(
            right: micZoneWidth, // its tappable rows must not reach under the mic's touch zone
            top: 30,
            width: 462,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.items.isEmpty ? 'KHÔNG CÒN VIỆC NÀO' : 'CÒN ${r.open} VIỆC · CHẠM ĐỂ ĐÁNH DẤU XONG', style: eyebrow()),
                const SizedBox(height: 4),
                for (final item in r.items) _Item(item: item, onTap: () => c.toggleDone(item.id)),
              ],
            ),
          ),
          Positioned(left: 0, top: 212, child: Timeline(events: c.plan.on(now), now: now, pins: todayPins(c))),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: ts(68, weight: FontWeight.w300, spacing: -2, height: 1)),
          const SizedBox(height: 10),
          Text(label, style: metaStyle(17)),
        ],
      );
}

class _Item extends StatelessWidget {
  const _Item({required this.item, required this.onTap});
  final RecapItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        key: Key('recap-${item.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 34,
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: item.done ? Ink.faint : null,
                  border: item.done ? null : Border.all(color: Ink.hot, width: 2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(19, color: item.done ? Ink.dim : Ink.ink).copyWith(
                    decoration: item.done ? TextDecoration.lineThrough : null,
                    decorationColor: Ink.dim,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
