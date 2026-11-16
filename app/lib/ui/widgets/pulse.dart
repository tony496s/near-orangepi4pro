import 'package:flutter/widgets.dart';

/// Slow opacity pulse (2.4 s) for something about to happen. Only used for a few minutes at a time: a continuous
/// animation keeps the GPU busy, and heat is a real constraint on the board.
class Pulse extends StatefulWidget {
  const Pulse({super.key, required this.child});
  final Widget child;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: Tween(begin: 1.0, end: .55).animate(_a), child: widget.child);
}

/// Fade in while rising 14 px: the entrance used for answers and confirmations.
Widget rise(Widget child, Animation<double> a) => FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, .12), end: Offset.zero).animate(a), child: child),
    );
