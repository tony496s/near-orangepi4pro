import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/core/vi_format.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/strip_layout.dart';
import 'package:near_app/ui/screens/columns.dart';
import 'package:near_app/ui/widgets/line_chart.dart';

import '../support/fakes.dart';
import '../support/fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  final day = DateTime(2026, 11, 16);

  void view(WidgetTester tester) {
    tester.view.physicalSize = const Size(1480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// A started controller; [panels] seeds the stored column set.
  Future<AppController> start(WidgetTester tester, DateTime at,
      {List<String>? panels, CalendarSource? calendar}) async {
    final store = tempStore();
    if (panels != null) {
      store.file.writeAsStringSync(jsonEncode({
        'layout': {'panels': panels, 'split': true},
      }));
    }
    final c = AppController(
      clock: FakeClock(at),
      store: store,
      calendar: calendar ?? SampleCalendarSource(launchedAt: DateTime(at.year, at.month, at.day, 6)),
      voice: FakeVoice(),
      heardHold: Duration.zero,
      log: (_) {},
    );
    await tester.runAsync(() => c.start(ticker: false));
    return c;
  }

  Widget host(Widget child) => WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, _) => SizedBox(width: 1480, height: 320, child: child),
      );

  Future<AppController> pump(WidgetTester tester, DateTime at, {CalendarSource? calendar}) async {
    view(tester);
    final c = await start(tester, at, calendar: calendar);
    await tester.pumpWidget(host(ListenableBuilder(listenable: c, builder: (context, _) => ColumnsScreen(c: c))));
    return c;
  }

  FakeClock clockOf(AppController c) => c.clock as FakeClock;

  /// Runs the timer of [c] to its end, as the app's ticker would.
  Future<void> endTimer(WidgetTester tester, AppController c) async {
    clockOf(c).advance(c.timer!.remaining(c.now));
    c.tick();
    await tester.pump();
  }

  double opacity(WidgetTester tester, int slot) =>
      tester.widget<Opacity>(find.byKey(ValueKey('column-rise-$slot'))).opacity;

  double glow(WidgetTester tester, String panel) {
    final box = tester.widget<DecoratedBox>(
        find.descendant(of: find.byKey(Key('column-glow-$panel')), matching: find.byType(DecoratedBox)).first);
    return (box.decoration as BoxDecoration).color!.a;
  }

  Finder inKey(String key, Finder f) => find.descendant(of: find.byKey(Key(key)), matching: f);

  /// No overflow, and every piece of text and every column left of the mic and VI/EN strip.
  void checkLayout(WidgetTester tester, AppController c, String reason) {
    expect(tester.takeException(), isNull, reason: '$reason: no overflow');
    for (final e in find.descendant(of: find.byType(ColumnsScreen), matching: find.byType(RichText)).evaluate()) {
      final box = e.renderObject! as RenderBox;
      final r = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
      final text = (e.widget as RichText).text.toPlainText();
      expect(r.left, greaterThanOrEqualTo(0), reason: '$reason: "$text"');
      expect(r.right, lessThanOrEqualTo(1360), reason: '$reason: "$text"');
    }
    for (final p in c.layout.panels) {
      expect(tester.getRect(find.byKey(Key('column-touch-${p.name}'))).right, lessThanOrEqualTo(1360),
          reason: '$reason: ${p.name}');
    }
  }

  test('viNumber uses dots for thousands and a comma for decimals', () {
    expect(viNumber(4146.2), '4.146,2');
    expect(viNumber(33.8), '33,8');
    expect(viNumber(0.82, decimals: 2), '0,82');
    expect(viNumber(1234567.25, decimals: 2), '1.234.567,25');
    expect(viNumber(-26.5), '-26,5');
    expect(viNumber(999.96), '1.000,0');
  });

  test('column widths: equal side by side; zoomed, 210 px rails and the rest for the held one', () {
    final even = ColumnsScreen.widths(3, 1360, null);
    expect(even, hasLength(3));
    expect(even.reduce((a, b) => a + b) + 2, closeTo(1360, 1e-9), reason: 'two 1 px separators');
    expect(even.first, closeTo(1358 / 3, 1e-9));
    expect(ColumnsScreen.widths(3, 1360, 1), [210, 938, 210]);
    expect(ColumnsScreen.widths(3, 1360, 0), [938, 210, 210]);
    expect(ColumnsScreen.widths(2, 1360, 1), [210, 1149]);
    expect(ColumnsScreen.widths(3, 1360, 7), even, reason: 'a zoom past the end is no zoom');
    expect(ColumnsScreen.widths(0, 1360, null), isEmpty);
  });

  test('the columns that rise again are the ones whose panel changed', () {
    const set = [Panel.calendar, Panel.gold, Panel.timer];
    expect(ColumnsScreen.changed(set, set), isEmpty);
    expect(ColumnsScreen.changed(set, const [Panel.calendar, Panel.timer, Panel.gold]), [1, 2]);
    expect(ColumnsScreen.changed(const [Panel.calendar, Panel.gold], set), [2], reason: 'a new column rises');
    expect(ColumnsScreen.changed(set, const [Panel.calendar, Panel.gold]), isEmpty);
  });

  test('the done flash pulses .08 → .22 three times and ends on the soft glow', () {
    expect(flashAlpha(0), closeTo(.08, 1e-9));
    expect(flashAlpha(1 / 6), closeTo(.22, 1e-9));
    expect(flashAlpha(1 / 3), closeTo(.08, 1e-9));
    expect(flashAlpha(1), closeTo(.08, 1e-9));
    expect(flashAlpha(3), closeTo(.08, 1e-9), reason: 'clamped');
  });

  testWidgets('three panels: today, gold, an idle timer', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 30)));
    expect(tester.widget<Text>(find.byKey(const Key('columns-clock'))).data, '13:30');
    expect(find.text('13:30'), findsNWidgets(2), reason: 'the clock and the chart\'s last time label');
    expect(find.text('HÔM NAY · THỨ HAI 16/11'), findsOneWidget);
    expect(find.text('VÀNG · USD/OUNCE'), findsOneWidget);
    expect(find.text('Số liệu mẫu'), findsOneWidget);
    expect(find.text('Chưa chạy'), findsOneWidget);
    expect(find.text('Nói “hẹn giờ … phút”'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('gold-price'))).data, viNumber(c.gold.last));
    expect(find.textContaining('hôm nay'), findsOneWidget, reason: 'change since midnight');
    expect(find.textContaining('Sau đó: '), findsOneWidget);
  });

  testWidgets('a running timer counts down in its column, its length in the header', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 31)));
    c.run(const StartTimer(Duration(minutes: 45), focus: false));
    await tester.pump();
    expect(find.text('45:00'), findsOneWidget);
    expect(find.text('Kết thúc 14:16'), findsOneWidget);
    expect(find.text('HẸN GIỜ · 45 PHÚT'), findsOneWidget);
    expect(find.text('Chưa chạy'), findsNothing);
  });

  testWidgets('a focus session keeps the TẬP TRUNG header', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 9, minutes: 20)));
    c.run(const StartTimer(Duration(minutes: 25), focus: true));
    await tester.pump();
    expect(find.text('TẬP TRUNG'), findsOneWidget);
    expect(find.textContaining('HẸN GIỜ'), findsNothing);
    expect(find.text('25:00'), findsOneWidget);
  });

  testWidgets('panels stay left of the mic and VI/EN strip', (tester) async {
    await pump(tester, day.add(const Duration(hours: 9)));
    for (final k in const ['column-calendar', 'column-gold', 'column-timer']) {
      final r = tester.getRect(find.byKey(Key(k)));
      expect(r.right, lessThanOrEqualTo(1360), reason: k);
      expect(r.width, greaterThan(300), reason: k);
    }
    expect(tester.takeException(), isNull, reason: 'no overflow');
  });

  testWidgets('hold a column to zoom it; the others shrink to rails; tap to zoom back', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 30)));
    c.run(const StartTimer(Duration(minutes: 45), focus: false));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('column-touch-gold')));
    await tester.pump();
    final gold = tester.getRect(find.byKey(const Key('column-gold')));
    expect(gold.width, greaterThan(900), reason: 'the zoomed column takes the room');
    expect(gold.right, lessThanOrEqualTo(1360));
    expect(find.byKey(const Key('column-calendar')), findsNothing);
    expect(find.byKey(const Key('column-rail-calendar')), findsOneWidget);
    expect(find.text('TIẾP THEO'), findsOneWidget);
    expect(find.byKey(const Key('column-rail-timer')), findsOneWidget);
    expect(find.text('45:00'), findsOneWidget, reason: 'the shrunk timer still counts down');
    expect(c.screen, Screen.home, reason: 'a hold zooms; it does not open the chart');
    expect(tester.takeException(), isNull, reason: 'no overflow');

    await tester.tap(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    expect(find.byKey(const Key('column-calendar')), findsOneWidget, reason: 'tap anywhere zooms back');
    expect(find.byKey(const Key('column-rail-timer')), findsNothing);
    expect(c.screen, Screen.home, reason: 'the tap only zoomed back');
  });

  testWidgets('hold the zoomed column again to zoom back', (tester) async {
    await pump(tester, day.add(const Duration(hours: 9)));
    await tester.longPress(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    expect(find.byKey(const Key('column-rail-gold')), findsOneWidget);
    await tester.longPress(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    expect(find.byKey(const Key('column-rail-gold')), findsNothing);
    expect(find.byKey(const Key('column-gold')), findsOneWidget);
  });

  testWidgets('a tap on the gold column opens the chart; taps on the others do not', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 9)));
    expect(c.screen, Screen.brief, reason: 'a first start in the morning opens the morning brief');
    c.dismissBrief();
    await tester.tap(find.byKey(const Key('column-touch-calendar')));
    await tester.tap(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    expect(c.screen, Screen.home);
    await tester.tap(find.byKey(const Key('column-touch-gold')));
    await tester.pump();
    expect(c.screen, Screen.gold);
    expect(c.goldCompare, isFalse);
  });

  testWidgets('rails: clock and next event, the countdown and its end, the price and its change today',
      (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 30)));
    c.run(const StartTimer(Duration(minutes: 45), focus: false));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('column-touch-gold')));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const Key('column-rail-calendar'))).width, ColumnsScreen.railWidth);
    expect(tester.getRect(find.byKey(const Key('column-rail-timer'))).width, ColumnsScreen.railWidth);
    for (final t in ['13:30', 'TIẾP THEO', '1:1 · 14:30', 'còn 1 giờ']) {
      expect(inKey('column-rail-calendar', find.text(t)), findsOneWidget, reason: t);
    }
    for (final t in ['HẸN GIỜ', '45:00', 'Kết thúc 14:15']) {
      expect(inKey('column-rail-timer', find.text(t)), findsOneWidget, reason: t);
    }
    checkLayout(tester, c, 'gold zoomed');

    await tester.tap(find.byKey(const Key('column-touch-calendar')));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('column-touch-timer')));
    await tester.pumpAndSettle();
    final g = c.gold;
    final pct = '${g.change >= 0 ? '+' : '-'}${viNumber(g.changePct.abs(), decimals: 2)}% hôm nay';
    for (final t in ['VÀNG', viNumber(g.last), pct]) {
      expect(inKey('column-rail-gold', find.text(t)), findsOneWidget, reason: t);
    }
    expect(find.byKey(const Key('column-rail-calendar')), findsOneWidget);
    checkLayout(tester, c, 'timer zoomed');
  });

  testWidgets('a rail with nothing left today shows the first event tomorrow; an idle timer rail says so',
      (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 18)));
    await tester.longPress(find.byKey(const Key('column-touch-gold')));
    await tester.pumpAndSettle();
    expect(inKey('column-rail-calendar', find.text('NGÀY MAI')), findsOneWidget);
    expect(inKey('column-rail-calendar', find.text('Sync với team design · 08:30')), findsOneWidget);
    expect(inKey('column-rail-timer', find.text('Chưa chạy')), findsOneWidget);
    checkLayout(tester, c, 'evening, gold zoomed');
  });

  testWidgets('the zoomed gold column: price, change today, high and low, a chart with prices on the right',
      (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 30)));
    await tester.longPress(find.byKey(const Key('column-touch-gold')));
    await tester.pumpAndSettle();
    final g = c.gold;
    final sign = g.change >= 0 ? '+' : '-';
    expect(find.text('VÀNG THẾ GIỚI · USD/OUNCE · HÔM NAY'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('gold-zoom-price'))).data, viNumber(g.last));
    expect(tester.widget<Text>(find.byKey(const Key('gold-zoom-change'))).data,
        '$sign${viNumber(g.change.abs())} ($sign${viNumber(g.changePct.abs(), decimals: 2)}%) hôm nay');
    expect(tester.widget<Text>(find.byKey(const Key('gold-zoom-range'))).data,
        'cao nhất ${viNumber(g.high)} · thấp nhất ${viNumber(g.low)}');
    final chartFinder = inKey('column-gold', find.byType(LineChart));
    final chart = tester.widget<LineChart>(chartFinder);
    expect(chart.yLabels, isTrue);
    expect(chart.labels, isTrue);
    expect(chart.startLabel, '00:00');
    expect(chart.midLabel, isNotEmpty);
    expect(chart.endLabel, '13:30');
    final r = tester.getRect(chartFinder);
    expect(r.width, greaterThan(850));
    expect(r.height, greaterThan(180));
    expect(find.byKey(const Key('gold-price')), findsNothing, reason: 'the small column is replaced');
    checkLayout(tester, c, 'gold zoomed');
  });

  testWidgets('the zoomed timer: a big ring with the countdown, when it ends and started', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 30)));
    c.run(const StartTimer(Duration(minutes: 45), focus: false));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('column-touch-timer')));
    await tester.pumpAndSettle();
    expect(inKey('column-timer', find.text('HẸN GIỜ · 45 PHÚT')), findsOneWidget);
    expect(inKey('column-timer', find.text('Kết thúc 14:15')), findsOneWidget);
    expect(inKey('column-timer', find.text('Bắt đầu 13:30 · đã chạy 0 phút')), findsOneWidget);
    expect(tester.widget<Text>(inKey('column-timer', find.text('45:00'))).style!.fontSize, 60);
    expect(tester.getRect(find.byKey(const Key('column-timer'))).width, greaterThan(900));
    checkLayout(tester, c, 'timer zoomed');
  });

  testWidgets('the zoomed calendar lists the rest of today with times', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 30)));
    await tester.longPress(find.byKey(const Key('column-touch-calendar')));
    await tester.pumpAndSettle();
    expect(inKey('column-calendar', find.text('CÒN LẠI HÔM NAY')), findsOneWidget);
    for (final t in ['14:30–15:00', '16:00–17:00', 'Tập trung sâu', '17:00–17:45', 'Review', 'còn 1 giờ · 2 người']) {
      expect(inKey('column-calendar', find.text(t)), findsOneWidget, reason: t);
    }
    expect(inKey('column-calendar', find.text('Ăn trưa')), findsNothing, reason: 'it ended');
    expect(tester.widget<Text>(find.byKey(const Key('columns-clock'))).data, '13:30');
    checkLayout(tester, c, 'calendar zoomed');
  });

  testWidgets('a long day: the zoomed calendar shows what fits and how many more', (tester) async {
    final at = day.add(const Duration(hours: 8));
    final c = await pump(
      tester,
      at,
      calendar: FixedCalendar([
        for (var i = 0; i < 10; i++) ev('e$i', 'Việc số $i', day.add(Duration(hours: 9, minutes: 40 * i)), 30),
      ]),
    );
    await tester.longPress(find.byKey(const Key('column-touch-calendar')));
    await tester.pumpAndSettle();
    expect(inKey('column-calendar', find.text('+4 việc nữa')), findsOneWidget);
    expect(find.byKey(const Key('agenda-e5')), findsOneWidget);
    expect(find.byKey(const Key('agenda-e6')), findsNothing);
    expect(inKey('column-calendar', find.text('còn 1 giờ · Phòng 3')), findsOneWidget, reason: 'the next one');
    checkLayout(tester, c, 'long day');
  });

  testWidgets('a timer that ends shows in its column: full ring, Hết giờ, a flash; +10 phút, then Xong',
      (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 9, minutes: 30)));
    c.run(const StartTimer(Duration(minutes: 1), focus: false));
    await tester.pump();
    expect(find.text('HẸN GIỜ · 1 PHÚT'), findsOneWidget);
    expect(glow(tester, 'timer'), 0);
    await endTimer(tester, c);
    expect(c.timerDoneInColumn, isNotNull);
    expect(inKey('column-timer', find.text('Hết giờ')), findsOneWidget);
    expect(inKey('column-timer', find.text('+10 phút')), findsOneWidget);
    expect(inKey('column-timer', find.text('Xong')), findsOneWidget);
    expect(find.text('Chưa chạy'), findsNothing);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(glow(tester, 'timer'), closeTo(.22, .02), reason: 'half a pulse in: brightest');
    expect(glow(tester, 'gold'), 0, reason: 'only the timer column flashes');
    await tester.pumpAndSettle();
    expect(glow(tester, 'timer'), closeTo(.08, .005), reason: 'the flash ends on a soft glow');

    final col = tester.getRect(find.byKey(const Key('column-timer')));
    for (final k in const ['column-timer-primary', 'column-timer-secondary']) {
      final r = tester.getRect(find.byKey(Key(k)));
      expect(r.height, greaterThanOrEqualTo(48), reason: k);
      expect(r.left - 40, greaterThanOrEqualTo(col.left), reason: '$k: room for taps landing left of it');
      expect(r.right, lessThanOrEqualTo(col.right - 16), reason: k);
      expect(r.top, greaterThanOrEqualTo(col.top), reason: k);
      expect(r.bottom, lessThanOrEqualTo(col.bottom - 8), reason: k);
    }
    checkLayout(tester, c, 'done');

    await tester.tap(find.byKey(const Key('column-timer-primary')));
    await tester.pump();
    expect(c.alert, isNull);
    expect(c.timer!.duration, const Duration(minutes: 10));
    expect(c.screen, Screen.home);
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('HẸN GIỜ · 10 PHÚT'), findsOneWidget);
    expect(find.text('+10 phút'), findsNothing);
    await tester.pumpAndSettle();
    expect(glow(tester, 'timer'), 0);

    await endTimer(tester, c);
    expect(find.text('Xong'), findsOneWidget);
    await tester.tap(find.byKey(const Key('column-timer-secondary')));
    await tester.pump();
    expect(c.alert, isNull);
    expect(c.timer, isNull);
    expect(find.text('Chưa chạy'), findsOneWidget);
    expect(find.text('Hết giờ'), findsNothing);
    expect(find.text('Xong'), findsNothing);
    await tester.pumpAndSettle();
    expect(glow(tester, 'timer'), 0);
  });

  testWidgets('the done buttons also take taps landing left of them', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 9, minutes: 30)));
    c.run(const StartTimer(Duration(minutes: 1), focus: false));
    await tester.pump();
    await endTimer(tester, c);
    final p = tester.getRect(find.byKey(const Key('column-timer-primary')));
    await tester.tapAt(Offset(p.left - 36, p.center.dy));
    await tester.pump();
    expect(c.timer!.duration, const Duration(minutes: 10), reason: '+10 phút');

    await endTimer(tester, c);
    final s = tester.getRect(find.byKey(const Key('column-timer-secondary')));
    await tester.tapAt(Offset(s.left - 36, s.center.dy));
    await tester.pump();
    expect(c.alert, isNull, reason: 'Xong');
    expect(c.timer, isNull);
  });

  testWidgets('a timer that ends while another column is zoomed brings the columns back; zoomed on itself it stays',
      (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 9, minutes: 30)));
    c.run(const StartTimer(Duration(minutes: 1), focus: false));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('column-touch-gold')));
    await tester.pump();
    expect(find.byKey(const Key('column-rail-timer')), findsOneWidget);
    await endTimer(tester, c);
    expect(find.byKey(const Key('column-rail-timer')), findsNothing);
    expect(find.byKey(const Key('column-calendar')), findsOneWidget);
    expect(find.byKey(const Key('column-timer-primary')), findsOneWidget);
    await tester.tap(find.byKey(const Key('column-timer-secondary')));
    await tester.pump();

    c.run(const StartTimer(Duration(minutes: 1), focus: false));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    await endTimer(tester, c);
    expect(find.byKey(const Key('column-rail-gold')), findsOneWidget, reason: 'still zoomed on the timer');
    expect(inKey('column-timer', find.text('Hết 1 phút')), findsOneWidget);
    expect(find.byKey(const Key('column-timer-primary')), findsOneWidget);
    await tester.pumpAndSettle();
    checkLayout(tester, c, 'done, timer zoomed');
    await tester.tap(find.byKey(const Key('column-timer-primary')));
    await tester.pump();
    expect(c.timer!.duration, const Duration(minutes: 10));
  });

  testWidgets('no overflow and nothing right of x 1360, in every timer state and zoom', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 9, minutes: 30)));
    Future<void> everyZoom(String state) async {
      await tester.pumpAndSettle();
      checkLayout(tester, c, state);
      final panels = c.layout.panels;
      for (final p in panels) {
        await tester.longPress(find.byKey(Key('column-touch-${p.name}')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('column-${p.name}')), findsOneWidget, reason: '$state, ${p.name} zoomed');
        checkLayout(tester, c, '$state, ${p.name} zoomed');
        final other = panels.firstWhere((q) => q != p);
        await tester.tap(find.byKey(Key('column-touch-${other.name}')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('column-rail-${other.name}')), findsNothing, reason: '$state: zoomed back');
      }
    }

    await everyZoom('idle');
    c.run(const StartTimer(Duration(minutes: 45), focus: false));
    await everyZoom('running');
    c.run(const StartTimer(Duration(minutes: 90), focus: false));
    await everyZoom('running 90 minutes');
    c.run(const StartTimer(Duration(minutes: 25), focus: true));
    await everyZoom('focus');
    c.run(const StartTimer(Duration(minutes: 1), focus: false));
    await endTimer(tester, c);
    await everyZoom('done');
    c.alertAction(AlertAction.secondary);
    c.run(const StartTimer(Duration(minutes: 1), focus: true));
    await endTimer(tester, c);
    // A focus session ends on the whole strip ("Nghỉ 5 phút", the strip's alert screen), not in the column.
    expect(c.timerDoneInColumn, isNull);
    expect(find.byKey(const Key('column-timer-primary')), findsNothing);
    await everyZoom('focus done');
  });

  testWidgets('the columns rise in one after another, 120 ms apart, and settle', (tester) async {
    await pump(tester, day.add(const Duration(hours: 9)));
    await tester.pump();
    expect([for (var i = 0; i < 3; i++) opacity(tester, i)], [0, 0, 0]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester, 0), greaterThan(0));
    expect(opacity(tester, 1), 0);
    expect(opacity(tester, 2), 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester, 1), greaterThan(0));
    expect(opacity(tester, 2), 0);
    await tester.pumpAndSettle();
    expect([for (var i = 0; i < 3; i++) opacity(tester, i)], [1, 1, 1]);
    expect(tester.getRect(find.byKey(const Key('column-gold'))).top, 0, reason: 'risen into place');
  });

  testWidgets('a column whose panel changes rises in again; the others stay put', (tester) async {
    view(tester);
    final at = day.add(const Duration(hours: 13, minutes: 40));
    final a = await start(tester, at);
    final b = await start(tester, at, panels: const ['calendar', 'timer', 'gold']);
    expect(b.layout.panels, const [Panel.calendar, Panel.timer, Panel.gold]);
    final which = ValueNotifier(a);
    addTearDown(which.dispose);
    await tester.pumpWidget(
        host(ValueListenableBuilder(valueListenable: which, builder: (context, c, _) => ColumnsScreen(c: c))));
    await tester.pumpAndSettle();
    final goldBefore = tester.getRect(find.byKey(const Key('column-gold')));

    which.value = b;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester, 0), 1, reason: 'the calendar did not change');
    expect(opacity(tester, 1), 0, reason: 'still in the .15 s delay');
    expect(opacity(tester, 2), 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(tester, 1), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect([for (var i = 0; i < 3; i++) opacity(tester, i)], [1, 1, 1]);
    expect(tester.getRect(find.byKey(const Key('column-gold'))).left, greaterThan(goldBefore.left));
    expect(tester.takeException(), isNull);
  });

  testWidgets('USD/VND in the middle: its column, its zoom and its rail, without overflow', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 40)));
    c.run(const SwapPanel(Panel.fx, index: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('column-fx')), findsOneWidget);
    expect(find.byKey(const Key('column-gold')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('fx-price'))).data, viNumber(c.fx.last, decimals: 0));

    await tester.longPress(find.byKey(const Key('column-touch-fx')));
    await tester.pumpAndSettle();
    final zoom = tester.getRect(find.byKey(const Key('column-fx')));
    expect(zoom.width, greaterThan(900));
    expect(zoom.right, lessThanOrEqualTo(1360));
    expect(find.byKey(const Key('fx-zoom-price')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'FxZoom fits the zoomed width with two rails');

    await tester.tap(find.byKey(const Key('column-touch-fx')));
    await tester.pumpAndSettle();
    expect(c.screen, Screen.home, reason: 'a tap only zooms back; fx has no screen of its own');
    await tester.longPress(find.byKey(const Key('column-touch-timer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('column-rail-fx')), findsOneWidget);
    final rail = tester.getRect(find.byKey(const Key('fx-rail-price')));
    expect(rail.width, lessThanOrEqualTo(ColumnsScreen.railWidth));
    expect(tester.takeException(), isNull);
  });
}
