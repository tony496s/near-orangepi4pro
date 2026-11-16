import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../ui/theme.dart';
import '../ui/widgets/sky.dart';
import 'agent_console.dart';
import 'console_layout.dart';
import 'console_model.dart';
import 'why_screen.dart';

/// Colours of the agent console, on top of the strip's [Ink] tokens.
abstract final class Tone {
  static const danger = Color(0xFFFF7A66);
  static const dangerBg = Color(0x2EFF5A44);
  static const card = Color(0x1AF2EEE6);
  static const code = Color(0xFF0B1216);
}

const mono = 'NearMono';

/// Text in the app font, with the mono font as the fallback for symbols (✓ ✗ ★ →).
TextStyle cs(double size, {FontWeight weight = FontWeight.w400, Color color = Ink.ink, double spacing = 0, double? height}) =>
    ts(size, weight: weight, color: color, spacing: spacing, height: height).copyWith(fontFamilyFallback: const [mono]);

/// Vietnamese letters: the mono font has no precomposed ỗ, ữ… and stacks their marks badly.
final _vietnamese = RegExp('[À-ỹ]');

/// A log line: tool calls in the mono font, the agent's own Vietnamese lines in the app font.
TextStyle lineStyle(String line, double size, Color color) =>
    _vietnamese.hasMatch(line) ? cs(size, color: color, height: 1.35) : logStyle(size, color);

TextStyle logStyle(double size, Color color) =>
    TextStyle(fontFamily: mono, fontSize: size, color: color, height: 1.35, fontFamilyFallback: const [fontFamily]);

Color stateColor(LaneState s) => switch (s) {
      LaneState.running => Ink.cool,
      LaneState.asking || LaneState.review || LaneState.shipping => Ink.hot,
      LaneState.blocked => Tone.danger,
      LaneState.ready => Ink.cool,
      LaneState.done => Ink.dim,
    };

/// Run time as m:ss, or h:mm:ss from an hour on.
String clock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final s = two(d.inSeconds % 60);
  return d.inHours > 0 ? '${d.inHours}:${two(d.inMinutes % 60)}:$s' : '${d.inMinutes}:$s';
}

/// Root of the agent console: the 1480x320 strip scaled to the screen.
class ConsoleApp extends StatelessWidget {
  const ConsoleApp({super.key, required this.console});
  final AgentConsole console;

  @override
  Widget build(BuildContext context) => WidgetsApp(
        color: Ink.bezel,
        debugShowCheckedModeBanner: false,
        textStyle: cs(16),
        builder: (context, _) => ColoredBox(
          color: Ink.bezel,
          child: FittedBox(
            child: SizedBox(
              width: stripWidth,
              height: stripHeight,
              child: ClipRect(
                child: ListenableBuilder(listenable: console, builder: (context, _) => ConsoleStrip(c: console)),
              ),
            ),
          ),
        ),
      );
}

class ConsoleStrip extends StatelessWidget {
  const ConsoleStrip({super.key, required this.c});
  final AgentConsole c;

  @override
  Widget build(BuildContext context) {
    final slotActive = c.voicePhase != VoicePhase.idle || c.note != null;
    final slotW = slotActive ? slotActiveWidth : slotIdleWidth;
    final widths = laneWidths([for (final l in c.lanes) l.card], stripWidth - railWidth - slotW);
    return Stack(
      children: [
        const Positioned.fill(child: Sky(kind: SkyKind.focus, glowX: 900)),
        Row(
          children: [
            Rail(c: c),
            // Lanes animate to new widths one by one, so mid-animation they may add up to more than the space: the
            // extra is clipped instead of pushing the slot off the strip.
            Expanded(
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < c.lanes.length; i++)
                        LaneView(key: ValueKey(c.lanes[i].id), c: c, lane: c.lanes[i], width: widths[i]),
                    ],
                  ),
                ),
              ),
            ),
            Slot(c: c, width: slotW),
          ],
        ),
        if (c.why) Positioned.fill(child: WhyScreen(onClose: () => c.showWhy(false))),
      ],
    );
  }
}

/// Left rail: how many agents the box runs and why that is safe. Tap: the comparison screen; double tap: autoplay on
/// or off; long press: start over.
class Rail extends StatelessWidget {
  const Rail({super.key, required this.c});
  final AgentConsole c;

  @override
  Widget build(BuildContext context) {
    final ram = c.ramGb.toStringAsFixed(1).replaceAll('.', ',');
    return GestureDetector(
      key: const Key('rail'),
      behavior: HitTestBehavior.opaque,
      onTap: () => c.showWhy(true),
      onDoubleTap: () => c.setAutoplay(!c.autoplay),
      onLongPress: c.reset,
      child: Container(
        width: railWidth,
        padding: const EdgeInsets.fromLTRB(22, 18, 12, 16),
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: Ink.hair))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.autoplay ? 'NEAR · TỰ CHẠY' : 'NEAR · HỘP AGENT',
                style: cs(13, weight: FontWeight.w600, color: c.autoplay ? Ink.cool : Ink.hot, spacing: 2.2)),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(children: [
                TextSpan(text: '${c.lanes.length}', style: cs(56, weight: FontWeight.w300, height: 1.05)),
                TextSpan(text: '  agent', style: cs(22, weight: FontWeight.w500)),
              ]),
            ),
            Text(
              c.running == c.lanes.length ? 'đang chạy trong hộp' : '${c.running} đang chạy · ${c.lanes.length - c.running} xong',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: cs(15, color: Ink.dim),
            ),
            const Spacer(),
            _RailRow(color: Ink.cool, text: 'Mac đã gập'),
            _RailRow(color: Ink.cool, text: 'Cách ly máy chính'),
            _RailRow(color: Ink.hot, text: 'Tự cho qua ${c.autoApproved} lệnh'),
            _RailRow(color: Ink.faint, text: 'RAM $ram / 6 GB'),
          ],
        ),
      ),
    );
  }
}

class _RailRow extends StatelessWidget {
  const _RailRow({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 7),
        child: Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: cs(15, color: Ink.dim))),
          ],
        ),
      );
}

/// One agent. Normal: repo, task, live log, progress. With a card: the card takes most of the (wider) lane.
class LaneView extends StatelessWidget {
  const LaneView({super.key, required this.c, required this.lane, required this.width});
  final AgentConsole c;
  final Lane lane;
  final double width;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        width: width,
        decoration: BoxDecoration(
          color: lane.card != null ? const Color(0x14F2EEE6) : null,
          border: const Border(right: BorderSide(color: Ink.hair)),
        ),
        child: ClipRect(
          child: LayoutBuilder(builder: (context, box) {
            final card = lane.card;
            final w = box.maxWidth;
            if (card != null && w >= cardMinWidth(card)) return _withCard(card, w);
            return Padding(padding: const EdgeInsets.fromLTRB(16, 16, 14, 14), child: _plain(w));
          }),
        ),
      );

  /// Narrowest lane that still shows [card] (the lane grows to it in about a third of a second).
  static double cardMinWidth(AgentCard card) => switch (card) {
        QuestionCard() => 470,
        DangerCard() => 500,
        ReviewCard() => 600,
        ShipCard() => 480,
      };

  Widget _plain(double w) {
    final narrow = w < 220;
    final now = c.clock.now();
    final color = stateColor(lane.state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(narrow),
        const SizedBox(height: 6),
        Text(
          lane.task,
          maxLines: narrow ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: cs(narrow ? 16 : 19, weight: FontWeight.w500, height: 1.25),
        ),
        const SizedBox(height: 8),
        Expanded(child: LogTail(lines: lane.log, size: narrow ? 12 : 13.5, live: lane.state == LaneState.running, beat: c.beat)),
        const SizedBox(height: 8),
        if (lane.state == LaneState.ready)
          _ShipButton(onTap: () => c.ship(lane), narrow: narrow)
        else ...[
          _Bar(value: lane.progress, color: color),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  lane.summary ?? lane.state.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: cs(narrow ? 13 : 15, weight: FontWeight.w600, color: color),
                ),
              ),
              const SizedBox(width: 6),
              Text(clock(lane.elapsed(now)), style: cs(narrow ? 13 : 15, color: Ink.dim)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _header(bool narrow) => Row(
        children: [
          _Dot(color: stateColor(lane.state), pulse: lane.state.needsHuman, beat: c.beat),
          const SizedBox(width: 8),
          Expanded(
            child: Text(lane.repo,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: cs(15, weight: FontWeight.w600, color: Ink.dim)),
          ),
          if (!narrow) ...[const SizedBox(width: 6), _EngineChip(lane.engine)],
        ],
      );

  Widget _withCard(AgentCard card, double w) {
    final now = c.clock.now();
    // The card keeps its room first; the repo/task column next to it takes what is left, up to 200.
    final infoW = (w - cardMinWidth(card) + 130).clamp(130.0, 200.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: infoW - 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(true),
                const SizedBox(height: 6),
                _EngineChip(lane.engine),
                const SizedBox(height: 10),
                Expanded(
                  child: Text(lane.task,
                      maxLines: 4, overflow: TextOverflow.ellipsis, style: cs(17, weight: FontWeight.w500, height: 1.25)),
                ),
                Text(clock(lane.elapsed(now)), style: cs(15, color: Ink.dim)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: switch (card) {
              QuestionCard() => QuestionView(card: card, onPick: (i) => c.resolve(lane, i)),
              DangerCard() => DangerView(card: card, onPick: (i) => c.resolve(lane, i)),
              ReviewCard() => ReviewView(card: card, beat: c.beat, onPick: (i) => c.resolve(lane, i)),
              ShipCard() => ShipView(card: card, beat: c.beat),
            },
          ),
        ],
      ),
    );
  }
}

/// The last lines of an agent's log, newest at the bottom and brightest; a blinking cursor while it works.
class LogTail extends StatelessWidget {
  const LogTail({super.key, required this.lines, required this.size, required this.live, required this.beat});
  final List<String> lines;
  final double size;
  final bool live;
  final int beat;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final lineH = size * 1.35;
        final n = math.max(0, (box.maxHeight / lineH).floor());
        final shown = lines.length > n ? lines.sublist(lines.length - n) : lines;
        return ClipRect(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < shown.length; i++)
                Text(
                  i == shown.length - 1 && live && (beat ~/ 3).isEven ? '${shown[i]} ▍' : shown[i],
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: lineStyle(
                    shown[i],
                    size,
                    i == shown.length - 1 ? Ink.ink : Color.lerp(Ink.faint, Ink.dim, (i + 1) / shown.length)!,
                  ),
                ),
            ],
          ),
        );
      });
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.pulse, required this.beat});
  final Color color;
  final bool pulse;
  final int beat;

  @override
  Widget build(BuildContext context) {
    final on = !pulse || (beat ~/ 3).isEven;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: on ? color : color.withValues(alpha: .25), shape: BoxShape.circle),
    );
  }
}

class _EngineChip extends StatelessWidget {
  const _EngineChip(this.engine);
  final Engine engine;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: Ink.hair, width: 1.5), borderRadius: BorderRadius.circular(8)),
        child: Text(engine.label.toUpperCase(), style: cs(11, weight: FontWeight.w600, color: Ink.dim, spacing: 1.2)),
      );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        height: 4,
        decoration: BoxDecoration(color: Ink.hair, borderRadius: BorderRadius.circular(2)),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 600),
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          ),
        ),
      );
}

class _ShipButton extends StatelessWidget {
  const _ShipButton({required this.onTap, required this.narrow});
  final VoidCallback onTap;
  final bool narrow;

  @override
  Widget build(BuildContext context) => Choice(
        key: const Key('ship'),
        label: narrow ? 'Ship' : 'Ship bản test',
        height: 52,
        style: ChoiceStyle.cool,
        onTap: onTap,
      );
}

enum ChoiceStyle { cool, ink, danger, outline }

/// A wide touch button on a card.
class Choice extends StatelessWidget {
  const Choice({super.key, required this.label, required this.onTap, this.style = ChoiceStyle.outline, this.height = 64});
  final String label;
  final VoidCallback onTap;
  final ChoiceStyle style;
  final double height;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (style) {
      ChoiceStyle.cool => (Ink.cool, Ink.onCool, Ink.cool),
      ChoiceStyle.ink => (Ink.ink, Ink.onInk, Ink.ink),
      ChoiceStyle.danger => (Tone.danger, const Color(0xFF2A0D08), Tone.danger),
      ChoiceStyle.outline => (const Color(0x00000000), Ink.ink, const Color(0x80F2EEE6)),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: 2),
          borderRadius: BorderRadius.circular(height / 2),
        ),
        // Shrinks rather than cuts the label when the lane is squeezed (five lanes and a card).
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label, maxLines: 1, style: cs(height > 56 ? 21 : 18, weight: FontWeight.w600, color: fg)),
        ),
      ),
    );
  }
}

Text eyebrowText(String s, Color color) =>
    Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: cs(13, weight: FontWeight.w600, color: color, spacing: 2));

class QuestionView extends StatelessWidget {
  const QuestionView({super.key, required this.card, required this.onPick});
  final QuestionCard card;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          eyebrowText('AGENT ĐANG HỎI ANH', Ink.hot),
          const SizedBox(height: 10),
          Text(card.question, maxLines: 3, overflow: TextOverflow.ellipsis, style: cs(24, weight: FontWeight.w500, height: 1.3)),
          const Spacer(),
          Row(
            children: [
              for (var i = 0; i < card.options.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(
                  child: Choice(
                    key: Key('option-$i'),
                    label: i == card.recommended ? '★ ${card.options[i]}' : card.options[i],
                    style: i == card.recommended ? ChoiceStyle.cool : ChoiceStyle.outline,
                    onTap: () => onPick(i),
                  ),
                ),
              ],
            ],
          ),
        ],
      );
}

class DangerView extends StatelessWidget {
  const DangerView({super.key, required this.card, required this.onPick});
  final DangerCard card;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Tone.dangerBg,
          border: Border.all(color: Tone.danger, width: 2),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            eyebrowText('LỆNH NGUY HIỂM · CHỜ ANH', Tone.danger),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(color: Tone.code, borderRadius: BorderRadius.circular(10)),
              child: Text('\$ ${card.command}',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: logStyle(17, Ink.ink).copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            Text(card.why, maxLines: 2, overflow: TextOverflow.ellipsis, style: cs(16, color: Ink.ink, height: 1.3)),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: Choice(
                      key: const Key('deny'), label: 'Từ chối', style: ChoiceStyle.ink, height: 56, onTap: () => onPick(DangerCard.deny)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Choice(
                      key: const Key('allow'), label: 'Cho phép', height: 56, onTap: () => onPick(DangerCard.allow)),
                ),
              ],
            ),
          ],
        ),
      );
}

class ReviewView extends StatelessWidget {
  const ReviewView({super.key, required this.card, required this.beat, required this.onPick});
  final ReviewCard card;
  final int beat;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LoginMock(label: 'TRƯỚC', loading: false, beat: beat),
          const SizedBox(width: 10),
          LoginMock(label: 'SAU', loading: true, beat: beat),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                eyebrowText('XONG · CHỜ DUYỆT', Ink.cool),
                const SizedBox(height: 10),
                _fit(Text('✓ Test ${card.tests}', maxLines: 1, style: cs(22, weight: FontWeight.w600))),
                const SizedBox(height: 2),
                _fit(Text('${card.diff} · ${card.files} file', maxLines: 1, style: cs(18, color: Ink.dim))),
                _fit(Text('Làm trong ${card.took}', maxLines: 1, style: cs(18, color: Ink.dim))),
                const Spacer(),
                Choice(key: const Key('approve'), label: 'Duyệt & tạo PR', style: ChoiceStyle.cool, height: 58, onTap: () => onPick(ReviewCard.approve)),
                const SizedBox(height: 10),
                Choice(key: const Key('redo'), label: 'Làm lại', height: 48, onTap: () => onPick(ReviewCard.redo)),
              ],
            ),
          ),
        ],
      );
}

Widget _fit(Widget child) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: child);

/// A tiny phone login screen, before (plain button) and after (spinner in the button) the change.
class LoginMock extends StatelessWidget {
  const LoginMock({super.key, required this.label, required this.loading, required this.beat});
  final String label;
  final bool loading;
  final int beat;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 124,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            eyebrowText(label, loading ? Ink.cool : Ink.dim),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E1A20),
                  border: Border.all(color: loading ? Ink.cool : const Color(0x33F2EEE6), width: 1.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Đăng nhập', style: cs(14, weight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    _field(),
                    const SizedBox(height: 7),
                    _field(),
                    const Spacer(),
                    Container(
                      height: 32,
                      decoration: BoxDecoration(
                        color: loading ? Ink.cool.withValues(alpha: .55) : Ink.cool,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (loading) ...[
                            SizedBox(width: 14, height: 14, child: CustomPaint(painter: SpinnerPainter(beat, Ink.onCool))),
                            const SizedBox(width: 6),
                          ],
                          Text(loading ? 'Đang vào' : 'Đăng nhập', style: cs(12, weight: FontWeight.w600, color: Ink.onCool)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _field() => Container(
        height: 22,
        decoration: BoxDecoration(border: Border.all(color: const Color(0x33F2EEE6)), borderRadius: BorderRadius.circular(6)),
      );
}

class SpinnerPainter extends CustomPainter {
  SpinnerPainter(this.beat, this.color);
  final int beat;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawArc(
      r.deflate(1.5),
      beat * .9,
      4.2,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(SpinnerPainter old) => old.beat != beat || old.color != color;
}

class ShipView extends StatelessWidget {
  const ShipView({super.key, required this.card, required this.beat});
  final ShipCard card;
  final int beat;

  @override
  Widget build(BuildContext context) {
    final done = card.done;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        eyebrowText(done ? 'ĐÃ LÊN TESTFLIGHT' : 'ĐANG SHIP BẢN TEST · TESTFLIGHT', done ? Ink.cool : Ink.hot),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < card.stages.length; i++)
              Expanded(child: _StageMark(label: card.stages[i], state: i < card.current ? 2 : (i == card.current ? 1 : 0), beat: beat)),
          ],
        ),
        const Spacer(),
        if (done) ...[
          Text('Bản ${card.version} đã lên TestFlight', maxLines: 1, overflow: TextOverflow.ellipsis, style: cs(26, weight: FontWeight.w600)),
          Text('Tester nhận thông báo trên iPhone', style: cs(16, color: Ink.dim)),
        ] else ...[
          Text('${card.stages[card.current]}…', style: cs(22, weight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text('Chạy trên CI, không cần mở laptop', style: cs(16, color: Ink.dim)),
        ],
      ],
    );
  }
}

class _StageMark extends StatelessWidget {
  const _StageMark({required this.label, required this.state, required this.beat});
  final String label;

  /// 0 waiting, 1 in progress, 2 done.
  final int state;
  final int beat;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: state == 2 ? Ink.cool : null,
              border: Border.all(color: state == 0 ? Ink.hair : (state == 1 ? Ink.hot : Ink.cool), width: 2),
            ),
            child: switch (state) {
              2 => Text('✓', style: cs(20, weight: FontWeight.w700, color: Ink.onCool)),
              1 => SizedBox(width: 22, height: 22, child: CustomPaint(painter: SpinnerPainter(beat, Ink.hot))),
              _ => null,
            },
          ),
          const SizedBox(height: 8),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: cs(15, weight: state == 1 ? FontWeight.w600 : FontWeight.w400, color: state == 0 ? Ink.dim : Ink.ink)),
        ],
      );
}

/// Right edge: give an agent work by voice. Tap: listen (tap again: done); long press while idle: the demo task
/// without speaking (in case the room is too loud).
class Slot extends StatelessWidget {
  const Slot({super.key, required this.c, required this.width});
  final AgentConsole c;
  final double width;

  static const fallbackTask = 'Thêm loading cho nút đăng nhập';

  @override
  Widget build(BuildContext context) {
    final listening = c.voicePhase == VoicePhase.listening;
    final processing = c.voicePhase == VoicePhase.processing;
    final note = c.note;
    return GestureDetector(
      key: const Key('slot'),
      behavior: HitTestBehavior.opaque,
      onTap: c.talk,
      onLongPress: () => c.voicePhase == VoicePhase.idle ? c.addTask(fallbackTask) : c.cancelTalk(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        width: width,
        color: listening || processing ? const Color(0x2286D8CC) : const Color(0x00000000),
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerRight,
            minWidth: 0,
            maxWidth: width,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 20, 16),
              child: listening
                  ? _listening()
                  : processing
                      ? _processing()
                      : note != null && width > slotIdleWidth + 40
                          ? Center(child: Text(note, textAlign: TextAlign.center, style: cs(19, weight: FontWeight.w500)))
                          : _idle(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _idle() => Column(
        children: [
          const Spacer(),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0x1AF2EEE6),
              border: Border.all(color: c.voiceReady ? Ink.cool : const Color(0x52F2EEE6), width: 2),
            ),
            child: CustomPaint(painter: MicGlyph()),
          ),
          const SizedBox(height: 10),
          Text('Giao việc', style: cs(17, weight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('chạm, hoặc nói\n“Hey Near”', textAlign: TextAlign.center, style: cs(13, color: Ink.dim, height: 1.3)),
          const Spacer(),
          if (c.langs.contains('en'))
            GestureDetector(
              key: const Key('lang'),
              behavior: HitTestBehavior.opaque,
              onTap: c.toggleLang,
              child: Container(
                width: 64,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.lang == 'en' ? Ink.cool : null,
                  border: Border.all(color: c.lang == 'en' ? Ink.cool : const Color(0x52F2EEE6), width: 1.5),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Text(c.lang.toUpperCase(),
                    style: cs(15, weight: FontWeight.w700, color: c.lang == 'en' ? Ink.onCool : Ink.dim, spacing: 1.5)),
              ),
            ),
        ],
      );

  Widget _listening() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          eyebrowText('ĐANG NGHE · ${c.lang.toUpperCase()}', Ink.cool),
          const Spacer(),
          SizedBox(height: 70, child: LevelBars(db: c.level, beat: c.beat)),
          const Spacer(),
          Text('Nói việc cần giao…', maxLines: 1, style: cs(22, weight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text('Chạm lần nữa khi nói xong', maxLines: 1, style: cs(15, color: Ink.dim)),
        ],
      );

  Widget _processing() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          eyebrowText('ĐANG CHÉP LỜI', Ink.cool),
          const Spacer(),
          Row(
            children: [
              SizedBox(width: 30, height: 30, child: CustomPaint(painter: SpinnerPainter(c.beat, Ink.cool))),
              const SizedBox(width: 14),
              Expanded(child: Text('Đang hiểu ý anh…', maxLines: 1, style: cs(22, weight: FontWeight.w500))),
            ],
          ),
          const Spacer(),
          Text(c.lang == 'vi' ? 'Chạy ngay trên board, không lên cloud' : 'Tiếng Anh: qua Harness',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: cs(15, color: Ink.dim)),
        ],
      );
}

/// Mic level as bars: louder speech, taller bars; a slow ripple keeps them alive between level updates.
class LevelBars extends StatelessWidget {
  const LevelBars({super.key, required this.db, required this.beat});
  final double db;
  final int beat;

  @override
  Widget build(BuildContext context) {
    final loud = ((db + 60) / 45).clamp(0.08, 1.0);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < 14; i++) ...[
          Container(
            width: 9,
            height: 70 * (0.15 + 0.85 * loud * (0.45 + 0.55 * math.sin(i * 1.3 + beat * .9).abs())),
            decoration: BoxDecoration(color: Ink.cool, borderRadius: BorderRadius.circular(4.5)),
          ),
          const SizedBox(width: 7),
        ],
      ],
    );
  }
}

class MicGlyph extends CustomPainter {
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
  bool shouldRepaint(MicGlyph oldDelegate) => false;
}
