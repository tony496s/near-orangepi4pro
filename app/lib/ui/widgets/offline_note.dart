import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/live_presenter.dart';
import '../theme.dart';

/// The demo's `.off-dot`: a small hollow ring before "MẤT MẠNG".
class OffDot extends StatelessWidget {
  const OffDot({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        margin: const EdgeInsets.only(right: 10),
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Ink.dim, width: 2)),
      );
}

/// The offline card in the middle of the day strip (scenario 6, 15:20): "● MẤT MẠNG", when the calendar was saved,
/// and that voice commands still work.
class OfflineCard extends StatelessWidget {
  const OfflineCard({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => Column(
        key: const Key('offline-card'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const OffDot(),
            Flexible(child: Text('MẤT MẠNG', maxLines: 1, overflow: TextOverflow.ellipsis, style: eyebrow(color: Ink.dim))),
          ]),
          const SizedBox(height: 10),
          Text(calendarSavedText(c.calendarFetchedAt, c.now), maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle()),
          Text('Lệnh giọng nói vẫn chạy', maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle()),
        ],
      );
}

/// One line for tight spots (under a timer, in the meeting clock, in the calendar column):
/// "● MẤT MẠNG · LỊCH LƯU LÚC 15:02".
class OfflineLine extends StatelessWidget {
  const OfflineLine({super.key, required this.c, this.size = 15});
  final AppController c;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
        key: const Key('offline-line'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const OffDot(),
          Flexible(
            child: Text(
              'MẤT MẠNG · ${calendarSavedText(c.calendarFetchedAt, c.now).toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: ts(size, weight: FontWeight.w600, color: Ink.dim, spacing: size * .12),
            ),
          ),
        ],
      );
}
