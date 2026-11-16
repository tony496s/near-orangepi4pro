import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/vi_format.dart';
import '../theme.dart';
import '../widgets/pulse.dart';
import '../widgets/sky.dart';

/// A focus session: big countdown, "do not disturb", and a card for answers or a meeting about to start.
class FocusScreen extends StatelessWidget {
  const FocusScreen({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final t = c.timer!;
    final f = c.flash;
    final session = c.sessionsToday.length + 1;
    return Sky(
      kind: SkyKind.focus,
      child: Stack(
        children: [
          Positioned(left: 44, top: 40, child: Text(hhmm(now), style: ts(44, spacing: -1, height: 1))),
          Positioned(
            left: 46,
            top: 106,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TẬP TRUNG', style: eyebrow(color: Ink.cool)),
                const SizedBox(height: 6),
                Text('Phiên $session hôm nay', style: metaStyle(18)),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 30,
            child: Text(mmss(t.remaining(now)),
                key: const Key('countdown'),
                textAlign: TextAlign.center,
                style: ts(168, weight: FontWeight.w200, spacing: -5, height: 1)),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 214,
            child: Text('KẾT THÚC LÚC ${hhmm(t.endsAt)}',
                textAlign: TextAlign.center, style: ts(16, weight: FontWeight.w500, color: Ink.dim, spacing: 16 * .18)),
          ),
          Positioned(
            right: micZoneWidth,
            top: 34,
            width: 382,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: rise,
              child: f == null
                  ? Padding(
                      key: const ValueKey('dnd'),
                      padding: const EdgeInsets.only(top: 10, right: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('KHÔNG LÀM PHIỀN', style: eyebrow(color: Ink.cool)),
                          const SizedBox(height: 10),
                          Text(c.fitDndLine ?? 'Nhắc việc tạm ẩn tới ${hhmm(t.endsAt)}', textAlign: TextAlign.right, style: metaStyle(18)),
                        ],
                      ),
                    )
                  : Container(
                      key: ValueKey('card|${f.title}'),
                      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                      decoration: BoxDecoration(
                        color: const Color(0x12F2EEE6),
                        border: Border.all(color: const Color(0x29F2EEE6)),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(f.eyebrow, style: eyebrow(color: f.cool ? Ink.cool : Ink.hot)),
                          const SizedBox(height: 6),
                          Text(f.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(34, weight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          Text(f.meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(18)),
                        ],
                      ),
                    ),
            ),
          ),
          Positioned(
            left: 44,
            right: 44,
            top: 270,
            child: _Bar(progress: t.progress(now)),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 4,
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(color: Color(0x24F2EEE6), borderRadius: BorderRadius.all(Radius.circular(2))))),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: box.maxWidth * progress,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Ink.cool,
                    borderRadius: BorderRadius.all(Radius.circular(2)),
                    boxShadow: [BoxShadow(color: Color(0x9986D8CC), blurRadius: 12)],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
