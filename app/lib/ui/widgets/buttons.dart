import 'package:flutter/widgets.dart';

import '../theme.dart';

enum PillStyle { outline, cool, ink }

/// A rounded touch button (76 px tall: easy to hit on a bar display).
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, required this.onTap, this.style = PillStyle.outline, this.small = false});

  final String label;
  final VoidCallback onTap;
  final PillStyle style;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (style) {
      PillStyle.outline => (const Color(0x00000000), Ink.ink, const Color(0x80F2EEE6)),
      PillStyle.cool => (Ink.cool, Ink.onCool, Ink.cool),
      PillStyle.ink => (Ink.ink, Ink.onInk, Ink.ink),
    };
    final h = small ? 52.0 : 76.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: h,
        constraints: BoxConstraints(minWidth: small ? 0 : 180),
        padding: EdgeInsets.symmetric(horizontal: small ? 22 : 34),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: 2),
          borderRadius: BorderRadius.circular(h / 2),
        ),
        child: Text(label, maxLines: 1, softWrap: false, style: ts(small ? 18 : 24, weight: FontWeight.w600, color: fg)),
      ),
    );
  }
}

/// The round mic button in the top-right corner. Dimmed while the voice service is not ready.
///
/// It fills the [micZoneWidth] x [micZoneHeight] corner, so place it at right 0, top 0: the whole zone takes the tap,
/// the circle is drawn 24 px from the right and 22 px from the top.
class MicButton extends StatelessWidget {
  const MicButton({super.key, required this.ready, required this.onTap, this.warning = false, this.dim = false});

  final bool ready;
  final VoidCallback onTap;

  /// Night peek: keep it as dark as the rest of the screen.
  final bool dim;

  /// A small amber dot: saving to disk is failing.
  final bool warning;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('mic'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: micZoneWidth,
        height: micZoneHeight,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 22, right: 24),
            child: SizedBox(key: const Key('mic-circle'), width: 64, height: 64, child: _circle()),
          ),
        ),
      ),
    );
  }

  Widget _circle() => Stack(
        children: [
          Opacity(
            opacity: (ready ? 1 : .4) * (dim ? .35 : 1),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x1AF2EEE6),
                border: Border.all(color: const Color(0x52F2EEE6), width: 1.5),
              ),
              child: CustomPaint(painter: _MicGlyph()),
            ),
          ),
          if (warning)
            Positioned(
              right: 2,
              top: 2,
              child: Container(width: 12, height: 12, decoration: const BoxDecoration(color: Ink.hot, shape: BoxShape.circle)),
            ),
        ],
      );
}

class _MicGlyph extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final stroke = Paint()
      ..color = Ink.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: c.translate(0, -5), width: 12, height: 20), const Radius.circular(6)),
      Paint()..color = Ink.ink,
    );
    canvas.drawArc(Rect.fromCenter(center: c.translate(0, -3), width: 22, height: 22), 0.15, 2.84, false, stroke);
    canvas.drawLine(c.translate(0, 8), c.translate(0, 14), stroke);
  }

  @override
  bool shouldRepaint(_MicGlyph oldDelegate) => false;
}
