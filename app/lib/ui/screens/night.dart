import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/vi_format.dart';
import '../../domain/intent/commands.dart';
import '../theme.dart';
import '../widgets/buttons.dart';

/// Night: a black screen (the backlight cannot be dimmed from software on this display). A tap shows a dim clock and
/// the first thing in the morning for 10 seconds.
class NightScreen extends StatelessWidget {
  const NightScreen({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    if (!c.peeking) return const ColoredBox(color: Color(0xFF000000), child: SizedBox.expand());
    final now = c.now;
    final morning = now.hour < 12 ? c.plan.on(now).where((e) => e.start.isAfter(now)).firstOrNull : c.plan.firstTomorrow(now);
    return ColoredBox(
      color: const Color(0xFF000000),
      child: Stack(
        children: [
          Positioned(left: 44, top: 70, child: Text(hhmm(now), style: ts(132, weight: FontWeight.w200, color: Ink.night1, spacing: -4, height: 1))),
          if (morning != null)
            Positioned(
              right: 44,
              top: 96,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(now.hour < 12 ? 'SÁNG NAY' : 'SÁNG MAI', style: eyebrow(color: Ink.night2)),
                  const SizedBox(height: 8),
                  Text('${hhmm(morning.start)} · ${morning.title}', style: ts(30, weight: FontWeight.w500, color: Ink.night2)),
                ],
              ),
            ),
          if (c.manualNight)
            Positioned(
              right: 44,
              top: 210,
              child: Pill('Bật màn', key: const Key('screen-on'), small: true, onTap: () => c.run(const ScreenOn())),
            )
          else
            Positioned(
              right: 44,
              top: 270,
              child: Text('TỰ TẮT SAU 10 GIÂY', style: ts(14, color: Ink.night3, spacing: 14 * .12)),
            ),
        ],
      ),
    );
  }
}
