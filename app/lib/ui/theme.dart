import 'package:flutter/widgets.dart';

/// Device screen tokens, from near-demo.html (the screen looks the same in light and dark rooms).
abstract final class Ink {
  static const bezel = Color(0xFF0A0B0D);
  static const ink = Color(0xFFF2EEE6);
  static const dim = Color(0xA3F2EEE6); // .64
  static const faint = Color(0x4DF2EEE6); // .30
  static const hair = Color(0x1FF2EEE6); // .12
  static const hot = Color(0xFFFFB36B);
  static const cool = Color(0xFF86D8CC);
  static const onCool = Color(0xFF06222A);
  static const onInk = Color(0xFF3B2416);
  static const night1 = Color(0xFF8A5638);
  static const night2 = Color(0xFF7A4C32);
  static const night3 = Color(0xFF4D3122);
}

const fontFamily = 'BeVietnamPro';

TextStyle ts(double size, {FontWeight weight = FontWeight.w400, Color color = Ink.ink, double spacing = 0, double? height}) =>
    TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: spacing,
      height: height ?? 1.25,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// Small upper-case label above a value ("TIẾP THEO").
TextStyle eyebrow({Color color = Ink.hot}) => ts(15, weight: FontWeight.w600, color: color, spacing: 15 * .18);

TextStyle metaStyle([double size = 20]) => ts(size, color: Ink.dim);

/// Background gradients: top colour, bottom colour, glow colour.
enum SkyKind {
  morning(Color(0xFF0F2440), Color(0xFF2B5577), Color(0x8CFFAA64)),
  late(Color(0xFF123A5C), Color(0xFF3A7192), Color(0x73FFCD8C)),
  afternoon(Color(0xFF0F3E55), Color(0xFF2E6F80), Color(0x61FFE1AA)),
  evening(Color(0xFF231A3D), Color(0xFF74405A), Color(0x8CFF8C5A)),
  focus(Color(0xFF06171F), Color(0xFF0C2A31), Color(0x2986D8CC)),
  done(Color(0xFF0C2F3A), Color(0xFF1D5960), Color(0x5986D8CC)),
  alert(Color(0xFF3B2416), Color(0xFF8C4C22), Color(0x99FFC482));

  const SkyKind(this.top, this.bottom, this.glow);
  final Color top;
  final Color bottom;
  final Color glow;

  static SkyKind at(DateTime t) {
    final h = t.hour + t.minute / 60;
    if (h < 10) return morning;
    if (h < 12) return late;
    if (h < 17) return afternoon;
    return evening;
  }
}

const stripWidth = 1480.0;
const stripHeight = 320.0;

/// Touch area of the mic button: the whole top-right corner, much larger than the 64 px circle drawn in it. On the
/// board, taps aimed at the circle land 30-45 px left of it (measured 16/11: x 1381-1390 for a circle at 1392-1456),
/// so a circle-sized target missed every tap. Screen content stays left of this zone.
const micZoneWidth = 120.0;
const micZoneHeight = 140.0;
