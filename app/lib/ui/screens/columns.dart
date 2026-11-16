import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../app/presenter.dart';
import '../../core/vi_format.dart';
import '../../data/price_source.dart';
import '../../domain/intent/commands.dart';
import '../../domain/models.dart';
import '../../domain/strip_layout.dart';
import '../theme.dart';
import '../widgets/buttons.dart';
import '../widgets/line_chart.dart';
import 'fx_panel.dart';
import '../widgets/sky.dart';

/// The split home screen (scenario 5 of near-demo.html): one panel per column of [AppController.layout], across
/// x 0..[columnsRight]. The strip right of that, under the mic and the VI/EN switch, stays empty.
///
/// Touch: hold a column to zoom it (`colsExpanded` in the demo): it becomes the wide main view and the others shrink
/// to [railWidth] rails that still show the clock and what is next, the price, the countdown. Hold it again or tap
/// anywhere to zoom back. A tap on the gold column opens the full chart. Talking is by the mic button only here: the
/// strip's own long press is off on this screen.
///
/// A timer that ends shows in its column ([AppController.timerDoneInColumn]): full ring, "Hết giờ", a short flash and
/// the alert's two buttons.
///
/// Motion: the columns rise in 120 ms apart when the screen appears, a column whose panel changes rises again, and the
/// zoomed view rises in. Every animation ends (no endless pulse), so the strip goes back to idle frames.
///
/// Each panel kind is built by [_ColumnsScreenState._column], [_ColumnsScreenState._main] and
/// [_ColumnsScreenState._rail] (one switch each), which also set the `column-<panel>` / `column-rail-<panel>` keys.
class ColumnsScreen extends StatefulWidget {
  const ColumnsScreen({super.key, required this.c});
  final AppController c;

  static const columnsRight = stripWidth - micZoneWidth;

  /// Width of a column shrunk next to a zoomed one.
  static const railWidth = 210.0;

  /// Delay between the columns entering (`.col.in` with `animation-delay: k * 120ms`).
  static const enterStagger = Duration(milliseconds: 120);

  /// Widths of [count] columns across [width], with 1 px separators between them. With [zoomed], that column takes
  /// what the [railWidth] rails leave. The last width is the remainder, so the row never overflows by a rounding error.
  static List<double> widths(int count, double width, int? zoomed) {
    if (count <= 0) return const [];
    final free = math.max(width - (count - 1), 0.0);
    final out = zoomed == null || count == 1 || zoomed >= count
        ? List.filled(count, free / count)
        : [for (var i = 0; i < count; i++) i == zoomed ? math.max(free - railWidth * (count - 1), 0.0) : railWidth];
    final rest = out.take(count - 1).fold(0.0, (a, b) => a + b);
    out[count - 1] = math.max(free - rest, 0.0);
    return out;
  }

  /// Indices whose panel is new in [after] (changed, or past the end of [before]): those columns rise again.
  static List<int> changed(List<Panel> before, List<Panel> after) => [
        for (var i = 0; i < after.length; i++)
          if (i >= before.length || before[i] != after[i]) i,
      ];

  @override
  State<ColumnsScreen> createState() => _ColumnsScreenState();
}

/// `.col.in` and `.main.in`: rise .5s ease.
const _riseFor = Duration(milliseconds: 500);

/// `.rise`: rise .55s ease .15s.
const _swapDelay = Duration(milliseconds: 150);
const _swapFor = Duration(milliseconds: 550);

class _ColumnsScreenState extends State<ColumnsScreen> {
  int? _zoomed;
  late List<Panel> _panels;
  late List<_Cue> _cues;
  var _cueId = 0;
  TimerDoneAlert? _done;

  AppController get c => widget.c;

  @override
  void initState() {
    super.initState();
    _panels = List.of(c.layout.panels);
    _cues = [for (var i = 0; i < _panels.length; i++) _Cue(_cueId++, delay: ColumnsScreen.enterStagger * i)];
    _done = c.timerDoneInColumn;
  }

  @override
  void didUpdateWidget(ColumnsScreen old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Runs on every rebuild from the controller: replays the rise of columns whose panel changed, and brings a timer
  /// that just ended (with its buttons) back into view.
  void _sync() {
    final panels = c.layout.panels;
    final changed = ColumnsScreen.changed(_panels, panels);
    if (panels.length != _panels.length) _zoomed = null;
    if (changed.isNotEmpty || panels.length != _cues.length) {
      _cues = [
        for (var i = 0; i < panels.length; i++)
          changed.contains(i) || i >= _cues.length ? _Cue(_cueId++, delay: _swapDelay, duration: _swapFor) : _cues[i],
      ];
    }
    _panels = List.of(panels);
    final done = c.timerDoneInColumn;
    if (done != null && !identical(done, _done)) {
      final z = _zoomed;
      if (z != null && (z >= panels.length || panels[z] != Panel.timer)) _zoomed = null;
    }
    _done = done;
  }

  void _hold(int i) {
    c.touched();
    setState(() {
      _zoomed = _zoomed == i ? null : i;
      if (_zoomed != null && i < _cues.length) _cues[i] = _Cue(_cueId++);
    });
  }

  void _tap(Panel p) {
    c.touched();
    if (_zoomed != null) {
      setState(() => _zoomed = null);
      return;
    }
    switch (p) {
      case Panel.gold:
        c.run(const ShowGold());
      case Panel.calendar || Panel.timer || Panel.fx:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final panels = c.layout.panels;
    final zoomed = _zoomed != null && _zoomed! < panels.length ? _zoomed : null;
    final timerDone = _TimerView.of(c).done;
    return Sky(
      kind: SkyKind.at(now),
      glowX: ColumnsScreen.columnsRight / 2,
      child: Padding(
        padding: const EdgeInsets.only(right: micZoneWidth),
        child: LayoutBuilder(
          builder: (context, box) {
            final widths = ColumnsScreen.widths(panels.length, box.maxWidth, zoomed);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < panels.length; i++) ...[
                  if (i > 0) const _Separator(),
                  SizedBox(
                    width: widths[i],
                    child: _Rise(
                      slot: i,
                      cue: i < _cues.length ? _cues[i] : const _Cue(-1, duration: Duration.zero),
                      child: GestureDetector(
                        key: Key('column-touch-${panels[i].name}'),
                        behavior: HitTestBehavior.opaque,
                        onLongPress: () => _hold(i),
                        onTap: () => _tap(panels[i]),
                        child: _Flash(
                          key: Key('column-glow-${panels[i].name}'),
                          on: timerDone && panels[i] == Panel.timer,
                          child: zoomed == null
                              ? KeyedSubtree(key: Key('column-${panels[i].name}'), child: _column(panels[i]))
                              : zoomed == i
                                  ? KeyedSubtree(key: Key('column-${panels[i].name}'), child: _main(panels[i]))
                                  : KeyedSubtree(key: Key('column-rail-${panels[i].name}'), child: _rail(panels[i])),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// A column at its normal width, next to the others (about 450 px).
  Widget _column(Panel p) => switch (p) {
        Panel.calendar => CalendarPanel(c: c),
        Panel.gold => GoldPanel(c: c),
        Panel.timer => TimerPanel(c: c),
        Panel.fx => FxPanel(series: c.fx),
      };

  /// The held column, zoomed: what the rails leave (about 940 px with three columns).
  Widget _main(Panel p) => switch (p) {
        Panel.calendar => CalendarZoom(c: c),
        Panel.gold => GoldZoom(c: c),
        Panel.timer => TimerZoom(c: c),
        Panel.fx => FxZoom(series: c.fx),
      };

  /// A column shrunk to a [ColumnsScreen.railWidth] rail next to the zoomed one.
  Widget _rail(Panel p) => switch (p) {
        Panel.calendar => CalendarRail(c: c),
        Panel.gold => GoldRail(c: c),
        Panel.timer => TimerRail(c: c),
        Panel.fx => FxRail(series: c.fx),
      };
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, margin: const EdgeInsets.symmetric(vertical: 28), color: Ink.hair);
}

// ---------------------------------------------------------------- motion

/// One play of the rise ([_Rise]): after [delay], [duration] long. A new [id] plays it again.
@immutable
class _Cue {
  const _Cue(this.id, {this.delay = Duration.zero, this.duration = _riseFor});
  final int id;
  final Duration delay;
  final Duration duration;
}

/// Fades its child in while it rises 14 px (`@keyframes rise` in near-demo.html), each time its [cue] changes. The
/// child is hidden during the delay (`animation-fill-mode: both`).
class _Rise extends StatefulWidget {
  const _Rise({required this.slot, required this.cue, required this.child});
  final int slot;
  final _Cue cue;
  final Widget child;

  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, value: 1);
  Curve _curve = Curves.ease;

  @override
  void initState() {
    super.initState();
    _play();
  }

  @override
  void didUpdateWidget(_Rise old) {
    super.didUpdateWidget(old);
    if (old.cue.id != widget.cue.id) _play();
  }

  void _play() {
    final cue = widget.cue;
    final total = cue.delay + cue.duration;
    if (total <= Duration.zero) {
      _anim.value = 1;
      return;
    }
    _anim.duration = total;
    _curve = Interval(cue.delay.inMicroseconds / total.inMicroseconds, 1, curve: Curves.ease);
    _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          final v = _curve.transform(_anim.value);
          return Opacity(
            key: ValueKey('column-rise-${widget.slot}'),
            opacity: v,
            child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child),
          );
        },
        child: widget.child,
      );
}

/// Pulses the column background teal [_Flash.cycles] times when [on] turns true, then keeps the soft glow while on
/// (`.col.flash`, which pulses forever in the demo; here it stops so the board goes back to idle frames).
class _Flash extends StatefulWidget {
  const _Flash({super.key, required this.on, required this.child});
  final bool on;
  final Widget child;

  static const period = Duration(milliseconds: 1600);
  static const cycles = 3;

  @override
  State<_Flash> createState() => _FlashState();
}

/// Background alpha [t] (0..1) through a column flash: .08 → .22 → .08 per pulse, ending on .08.
double flashAlpha(double t) => .08 + .14 * (1 - math.cos(2 * math.pi * _Flash.cycles * t.clamp(0.0, 1.0))) / 2;

class _FlashState extends State<_Flash> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: _Flash.period * _Flash.cycles);

  @override
  void initState() {
    super.initState();
    if (widget.on) _anim.forward();
  }

  @override
  void didUpdateWidget(_Flash old) {
    super.didUpdateWidget(old);
    if (widget.on && !old.on) _anim.forward(from: 0);
    if (!widget.on && old.on) _anim.reset();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: widget.on ? Ink.cool.withValues(alpha: flashAlpha(_anim.value)) : const Color(0x00000000),
          ),
          child: child,
        ),
        child: widget.child,
      );
}

// ---------------------------------------------------------------- shared bits

const _pad = EdgeInsets.fromLTRB(40, 26, 32, 24);
const _railPad = EdgeInsets.fromLTRB(24, 30, 20, 24);
const _mainPad = EdgeInsets.fromLTRB(34, 26, 34, 22);

String _sign(double v) => v >= 0 ? '+' : '-';

/// "+12,3 (+0,30%) hôm nay"
String _goldChange(PriceSeries g) {
  final s = _sign(g.change);
  return '$s${viNumber(g.change.abs())} ($s${viNumber(g.changePct.abs(), decimals: 2)}%) hôm nay';
}

Color _tone(PriceSeries g) => g.change >= 0 ? Ink.cool : Ink.hot;

// ---------------------------------------------------------------- calendar

/// Today: clock, what is next (or the latest answer), and the two events after it.
class CalendarPanel extends StatelessWidget {
  const CalendarPanel({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final valid = c.clockValid;
    final block = stripBlock(c);
    final next = c.plan.next(now);
    final later = next == null
        ? const <String>[]
        : [
            for (final e in c.plan.remainingToday(now).where((e) => e.start.isAfter(next.start)).take(2))
              '${hhmm(e.start)} ${e.title}',
          ];
    return Padding(
      padding: _pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(valid ? 'HÔM NAY · ${shortDate(now).toUpperCase()}' : 'HÔM NAY', style: eyebrow(color: Ink.dim)),
          Text(
            valid ? hhmm(now) : '--:--',
            key: const Key('columns-clock'),
            style: ts(84, weight: FontWeight.w300, spacing: -2, height: 1.05),
          ),
          const SizedBox(height: 6),
          _Block(block),
          const Spacer(),
          if (later.isNotEmpty)
            Text('Sau đó: ${later.join(' · ')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(15)),
        ],
      ),
    );
  }
}

/// The strip block (answer, meeting soon, going on, next): eyebrow, title, meta.
class _Block extends StatelessWidget {
  const _Block(this.block, {this.titleSize = 30});
  final StripBlock block;
  final double titleSize;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(block.eyebrow,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: eyebrow(color: block.cool ? Ink.cool : Ink.hot)),
          const SizedBox(height: 2),
          Text(
            block.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts(titleSize, weight: FontWeight.w600, height: 1.15),
          ),
          Text(block.meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(17)),
        ],
      );
}

/// Today zoomed: the clock and the strip block on the left, the rest of today as a list with times on the right.
class CalendarZoom extends StatelessWidget {
  const CalendarZoom({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final valid = c.clockValid;
    return Padding(
      padding: _mainPad,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(valid ? 'HÔM NAY · ${shortDate(now).toUpperCase()}' : 'HÔM NAY',
                    style: eyebrow(color: Ink.dim)),
                Text(
                  valid ? hhmm(now) : '--:--',
                  key: const Key('columns-clock'),
                  style: ts(84, weight: FontWeight.w300, spacing: -2, height: 1.05),
                ),
                const SizedBox(height: 6),
                _Block(stripBlock(c), titleSize: 28),
              ],
            ),
          ),
          const SizedBox(width: 40),
          Expanded(child: _Agenda(c: c)),
        ],
      ),
    );
  }
}

/// "CÒN LẠI HÔM NAY": one row per event left today (time, title, where or how long), as many as fit, then "+N việc
/// nữa". The event going on has a teal time, the next one an amber time.
class _Agenda extends StatelessWidget {
  const _Agenda({required this.c});
  final AppController c;

  static const rowHeight = 34.0;
  static const headHeight = 30.0;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final events = c.plan.remainingToday(now);
    final next = c.plan.next(now);
    return LayoutBuilder(
      builder: (context, box) {
        final fit = math.max(1, ((box.maxHeight - headHeight) / rowHeight).floor());
        final shown = events.length <= fit ? events : events.take(fit - 1).toList();
        final more = events.length - shown.length;
        final first = c.plan.firstTomorrow(now);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: headHeight, child: Text('CÒN LẠI HÔM NAY', style: eyebrow(color: Ink.dim))),
            if (events.isEmpty) ...[
              Text('Hết lịch hôm nay', style: ts(24, weight: FontWeight.w600)),
              if (first != null)
                Text('Ngày mai: ${hhmm(first.start)} ${first.title}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(17)),
            ],
            for (final e in shown)
              SizedBox(
                key: Key('agenda-${e.id}'),
                height: rowHeight,
                child: _AgendaRow(e, now: now, next: e.id == next?.id),
              ),
            if (more > 0) SizedBox(height: rowHeight, child: Text('+$more việc nữa', style: metaStyle(16))),
          ],
        );
      },
    );
  }
}

class _AgendaRow extends StatelessWidget {
  const _AgendaRow(this.e, {required this.now, required this.next});
  final CalendarEvent e;
  final DateTime now;
  final bool next;

  @override
  Widget build(BuildContext context) {
    final ongoing = e.isOngoing(now);
    final meta = [
      if (ongoing) 'đang diễn ra',
      if (next && !ongoing) 'còn ${durationVi(e.start.difference(now))}',
      if (e.details.isNotEmpty) e.details,
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SizedBox(
          width: 132,
          child: Text(
            '${hhmm(e.start)}–${hhmm(e.end)}',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: ts(17, weight: FontWeight.w500, color: ongoing ? Ink.cool : (next ? Ink.hot : Ink.dim)),
          ),
        ),
        Flexible(
          child: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(21, weight: FontWeight.w600)),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(width: 14),
          Flexible(child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(16))),
        ],
      ],
    );
  }
}

/// Today as a rail: the clock, then "TIẾP THEO", the next event as "title · hh:mm" and how long until it.
class CalendarRail extends StatelessWidget {
  const CalendarRail({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final next = c.plan.next(now);
    final first = next == null ? c.plan.firstTomorrow(now) : null;
    final (label, title, until) = next != null
        ? ('TIẾP THEO', '${next.title} · ${hhmm(next.start)}', 'còn ${durationVi(next.start.difference(now))}')
        : first != null
            ? ('NGÀY MAI', '${first.title} · ${hhmm(first.start)}', '')
            : ('HÔM NAY', 'Hết lịch', '');
    return Padding(
      padding: _railPad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            c.clockValid ? hhmm(now) : '--:--',
            key: const Key('columns-clock'),
            style: ts(40, weight: FontWeight.w300, spacing: -1, height: 1.1),
          ),
          const SizedBox(height: 22),
          Text(label, style: eyebrow()),
          const SizedBox(height: 6),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(19, weight: FontWeight.w600)),
          if (until.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(until, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(16)),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- gold

/// World gold today: price, change since midnight, a small chart.
class GoldPanel extends StatelessWidget {
  const GoldPanel({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final g = c.gold;
    return Padding(
      padding: _pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('VÀNG · USD/OUNCE', style: eyebrow()),
              const Spacer(),
              Text('Số liệu mẫu', style: ts(12, color: Ink.faint)),
            ],
          ),
          Text(
            viNumber(g.last),
            key: const Key('gold-price'),
            style: ts(56, weight: FontWeight.w300, spacing: -1, height: 1.1),
          ),
          Text(_goldChange(g), style: ts(16, color: _tone(g))),
          const SizedBox(height: 10),
          Expanded(
            child: LineChart(points: g.points, labels: true, startLabel: '00:00', endLabel: hhmm(now)),
          ),
        ],
      ),
    );
  }
}

/// Gold zoomed: the price, the change today, the day's high and low, and a taller chart with prices on the right
/// (and the alert threshold, while one is armed).
class GoldZoom extends StatelessWidget {
  const GoldZoom({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final g = c.gold;
    final pts = g.points;
    final alert = c.goldAlert;
    final threshold = alert != null && !alert.fired ? alert.threshold : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 26, 34, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('VÀNG THẾ GIỚI · USD/OUNCE · HÔM NAY',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: eyebrow()),
              ),
              const SizedBox(width: 12),
              Text('Số liệu mẫu', style: ts(12, color: Ink.faint)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                viNumber(g.last),
                key: const Key('gold-zoom-price'),
                style: ts(40, weight: FontWeight.w300, spacing: -1, height: 1.15),
              ),
              const SizedBox(width: 18),
              Text(_goldChange(g), key: const Key('gold-zoom-change'), style: ts(17, color: _tone(g))),
              const SizedBox(width: 16),
              Flexible(
                child: Text(
                  'cao nhất ${viNumber(g.high)} · thấp nhất ${viNumber(g.low)}',
                  key: const Key('gold-zoom-range'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: metaStyle(17),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LineChart(
              points: pts,
              labels: true,
              yLabels: true,
              startLabel: '00:00',
              midLabel: pts.length >= 3 ? hhmm(pts[pts.length ~/ 2].at) : '',
              endLabel: hhmm(now),
              threshold: threshold,
              thresholdLabel: threshold == null
                  ? ''
                  : '${alert!.above ? 'Báo khi vượt' : 'Báo khi xuống dưới'} ${viPrice(threshold)}',
            ),
          ),
        ],
      ),
    );
  }
}

/// Gold as a rail: "VÀNG", the price, the change today in percent.
class GoldRail extends StatelessWidget {
  const GoldRail({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final g = c.gold;
    return Padding(
      padding: _railPad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('VÀNG', style: eyebrow()),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              viNumber(g.last),
              key: const Key('gold-rail-price'),
              style: ts(34, weight: FontWeight.w300, spacing: -1, height: 1.1),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_sign(g.change)}${viNumber(g.changePct.abs(), decimals: 2)}% hôm nay',
            key: const Key('gold-rail-change'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts(16, color: _tone(g)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- timer

enum _TimerPhase { idle, running, done }

/// What the timer column shows: a running countdown, a timer that just ended while the columns are home (its alert
/// shows in the column), or nothing. A timer started again while an old alert waits counts as running.
class _TimerView {
  const _TimerView._(this.phase, this.timer, this.alert, this.now);

  factory _TimerView.of(AppController c) {
    final now = c.now;
    final t = c.timer;
    if (t != null && !t.isDone(now)) return _TimerView._(_TimerPhase.running, t, null, now);
    final a = c.timerDoneInColumn;
    if (a != null) return _TimerView._(_TimerPhase.done, a.timer, a, now);
    return _TimerView._(_TimerPhase.idle, null, null, now);
  }

  final _TimerPhase phase;
  final ActiveTimer? timer;
  final TimerDoneAlert? alert;
  final DateTime now;

  bool get running => phase == _TimerPhase.running;
  bool get done => phase == _TimerPhase.done;
  bool get focus => timer?.focus ?? false;

  /// "TẬP TRUNG" for a focus session; "HẸN GIỜ · 45 PHÚT" while a plain timer runs; else "HẸN GIỜ".
  String get header {
    if (focus) return 'TẬP TRUNG';
    return running ? 'HẸN GIỜ · ${_length(timer!.duration)}' : 'HẸN GIỜ';
  }

  /// The rail is too narrow for the length.
  String get railHeader => focus ? 'TẬP TRUNG' : 'HẸN GIỜ';

  /// Share of the ring drawn: what is left while running (full at the start, as in the demo), full once ended.
  double get ring => switch (phase) {
        _TimerPhase.idle => 0,
        _TimerPhase.running => 1 - timer!.progress(now),
        _TimerPhase.done => 1,
      };

  String get countdown => mmss(timer!.remaining(now));
  String get endsAt => 'Kết thúc ${hhmm(timer!.endsAt)}';

  /// "45 PHÚT", "30 GIÂY", "1 PHÚT 30 GIÂY".
  static String _length(Duration d) {
    final s = d.inSeconds;
    if (s % 60 == 0) return '${s ~/ 60} PHÚT';
    if (s < 60) return '$s GIÂY';
    return '${s ~/ 60} PHÚT ${s % 60} GIÂY';
  }
}

/// The timer as a ring: the countdown while it runs, then "Hết giờ" with its two buttons, or an idle ring with how
/// to start one.
class TimerPanel extends StatelessWidget {
  const TimerPanel({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final v = _TimerView.of(c);
    return Padding(
      padding: _pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(v.header, maxLines: 1, overflow: TextOverflow.ellipsis, style: eyebrow(color: Ink.cool)),
          const SizedBox(height: 6),
          Expanded(child: Center(child: _Ring(v))),
          const SizedBox(height: 4),
          SizedBox(
            height: 56,
            child: Center(
              child: switch (v.phase) {
                _TimerPhase.running => Text(v.endsAt, style: metaStyle(16)),
                _TimerPhase.done => _DoneButtons(c: c, alert: v.alert!),
                _TimerPhase.idle => Text('Nói “hẹn giờ … phút”', style: metaStyle(15)),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The timer zoomed: a big ring with the countdown, and beside it when it ends, when it started (or the alert's
/// buttons once it has ended).
class TimerZoom extends StatelessWidget {
  const TimerZoom({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final v = _TimerView.of(c);
    final t = v.timer;
    final after = v.done ? alertText(c, v.alert!).meta : '';
    final (title, meta) = switch (v.phase) {
      _TimerPhase.running => (
          v.endsAt,
          'Bắt đầu ${hhmm(t!.startedAt)} · đã chạy ${durationVi(v.now.difference(t.startedAt))}',
        ),
      _TimerPhase.done => (
          'Hết ${durationVi(t!.duration)}',
          ['Lúc ${hhmm(t.endsAt)}', if (after.isNotEmpty) after].join(' · '),
        ),
      _TimerPhase.idle => ('Nói “hẹn giờ … phút”', 'hoặc “hẹn giờ 10 phút để tập trung”'),
    };
    return Padding(
      padding: _mainPad,
      child: Row(
        children: [
          _Ring(v, size: 248, countSize: 60, doneSize: 36, idleSize: 20),
          const SizedBox(width: 44),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.header, maxLines: 1, overflow: TextOverflow.ellipsis, style: eyebrow(color: Ink.cool)),
                const SizedBox(height: 10),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(v.running ? 40 : 34, weight: v.running ? FontWeight.w300 : FontWeight.w600, height: 1.15),
                ),
                const SizedBox(height: 6),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(18)),
                if (v.done) ...[
                  const SizedBox(height: 20),
                  _DoneButtons(c: c, alert: v.alert!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The timer as a rail: the label, a small ring with the countdown, and when it ends (or "Chưa chạy").
class TimerRail extends StatelessWidget {
  const TimerRail({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final v = _TimerView.of(c);
    return Padding(
      padding: _railPad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(v.railHeader, style: eyebrow(color: Ink.cool)),
          const SizedBox(height: 12),
          Center(child: _Ring(v, size: 116, countSize: 24, doneSize: 20, idleSize: 20, idle: '—')),
          const SizedBox(height: 12),
          Center(
            child: Text(
              v.phase == _TimerPhase.idle ? 'Chưa chạy' : v.endsAt,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: metaStyle(15),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ring of [_TimerView]: what it draws and the text in its centre. Without [size] it is as big as fits.
class _Ring extends StatelessWidget {
  const _Ring(this.v,
      {this.size, this.countSize = 40, this.doneSize = 28, this.idleSize = 17, this.idle = 'Chưa chạy'});
  final _TimerView v;
  final double? size;
  final double countSize;
  final double doneSize;
  final double idleSize;
  final String idle;

  @override
  Widget build(BuildContext context) {
    final center = switch (v.phase) {
      _TimerPhase.running => Text(v.countdown,
          style: ts(countSize, weight: FontWeight.w300, spacing: countSize >= 40 ? -1 : 0, height: 1.1)),
      _TimerPhase.done =>
        Text('Hết giờ', style: ts(doneSize, weight: FontWeight.w600, color: Ink.cool, height: 1.1)),
      _TimerPhase.idle => Text(idle, style: metaStyle(idleSize)),
    };
    final ring = CustomPaint(
      painter: _RingPainter(v.ring),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(_RingPainter.stroke * 2),
          child: FittedBox(fit: BoxFit.scaleDown, child: center),
        ),
      ),
    );
    final s = size;
    return s == null ? AspectRatio(aspectRatio: 1, child: ring) : SizedBox.square(dimension: s, child: ring);
  }
}

/// The ended timer's two buttons, from [alertText] ("+10 phút" filled, "Xong"), 52 px tall.
///
/// Taps on the board land 30-45 px left of where the finger aims (theme.dart), so each button also takes the taps in
/// the [reach] px left of it; the gap between the two belongs to the right one. Keep [reach] of room left of the row.
class _DoneButtons extends StatelessWidget {
  const _DoneButtons({required this.c, required this.alert});
  final AppController c;
  final TimerDoneAlert alert;

  static const reach = 40.0;

  @override
  Widget build(BuildContext context) {
    final a = alertText(c, alert);
    void primary() => c.alertAction(AlertAction.primary);
    void secondary() => c.alertAction(AlertAction.secondary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _reach(
          Pill(a.primary, key: const Key('column-timer-primary'), small: true, style: PillStyle.cool, onTap: primary),
          primary,
        ),
        _reach(Pill(a.secondary, key: const Key('column-timer-secondary'), small: true, onTap: secondary), secondary),
      ],
    );
  }

  static Widget _reach(Widget button, VoidCallback onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.only(left: reach), child: button),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress);
  final double progress;

  static const stroke = 7.0;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 - stroke;
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Ink.hair
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0, 1),
        false,
        Paint()
          ..color = Ink.cool
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}
