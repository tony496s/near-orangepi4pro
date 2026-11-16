import 'dart:async';

import 'package:flutter/widgets.dart';

/// Slow opacity pulse (2.4 s) for something about to happen.
///
/// It steps about 12 times a second instead of animating every frame: on the board each frame is a full redraw, and a
/// 60 Hz pulse kept the app at ~40% of a core (2% without it) for the 5 minutes before every meeting. A fade this slow
/// moves 0.04 of opacity per step, which does not show as stepping.
class Pulse extends StatefulWidget {
  const Pulse({super.key, required this.child});
  final Widget child;

  static const period = Duration(milliseconds: 2400);
  static const step = Duration(milliseconds: 80);

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> {
  late final Timer _timer;
  var _steps = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Pulse.step, (_) => setState(() => _steps++));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Opacity(opacity: pulseOpacity(Pulse.step * _steps), child: widget.child);
}

/// Opacity [t] into the pulse: 1 at the start, down to 0.55 at half a period, back to 1, linearly.
double pulseOpacity(Duration t, [Duration period = Pulse.period]) {
  final phase = (t.inMicroseconds % period.inMicroseconds) / period.inMicroseconds;
  final down = phase < .5 ? phase * 2 : (1 - phase) * 2;
  return 1 - .45 * down;
}

/// Fade in while rising 14 px: the entrance used for answers and confirmations.
Widget rise(Widget child, Animation<double> a) => FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, .12), end: Offset.zero).animate(a), child: child),
    );
