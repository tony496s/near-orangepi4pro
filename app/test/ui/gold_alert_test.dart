import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/core/vi_format.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/data/price_source.dart';
import 'package:near_app/domain/gold_alert.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/ui/screens/gold_alert.dart';
import 'package:near_app/ui/theme.dart' show micZoneWidth, stripWidth;
import 'package:near_app/ui/widgets/line_chart.dart';

import '../support/fakes.dart';
import '../support/fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  final day = DateTime(2026, 11, 16);
  DateTime at(int h, [int m = 0]) => day.add(Duration(hours: h, minutes: m));
  const right = stripWidth - micZoneWidth;

  late FakeClock clock;

  /// A controller at [now], and the strip showing the gold alert at the front of its queue ([shown] when given).
  Future<AppController> pump(WidgetTester tester, DateTime now, {GoldCrossedAlert? shown}) async {
    tester.view.physicalSize = const Size(1480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    clock = FakeClock(now);
    final c = AppController(
      clock: clock,
      store: tempStore(),
      calendar: SampleCalendarSource(launchedAt: DateTime(now.year, now.month, now.day, 6)),
      voice: FakeVoice(),
      heardHold: Duration.zero,
      log: (_) {},
    );
    await tester.runAsync(() => c.start(ticker: false));
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, _) => SizedBox(
          width: 1480,
          height: 320,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) {
              final a = shown ?? c.alert;
              return a is GoldCrossedAlert ? GoldAlertScreen(c: c, alert: a) : const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return c;
  }

  /// Sets an alert one dollar past today's price and runs the clock until the sample price crosses it.
  Future<GoldCrossedAlert> cross(WidgetTester tester, AppController c, {required bool up}) async {
    final last = c.gold.last;
    c.run(SetGoldAlert((up ? last + 1 : last - 1).roundToDouble()));
    expect(c.goldAlert!.above, up);
    for (var i = 0; i < 900 && c.alert == null; i++) {
      clock.advance(const Duration(seconds: 1));
      c.tick();
    }
    await tester.pump();
    expect(c.alert, isA<GoldCrossedAlert>(), reason: 'the sample price crosses within 15 minutes');
    return c.alert! as GoldCrossedAlert;
  }

  LineChart chart(WidgetTester tester) => tester.widget<LineChart>(find.byType(LineChart));

  testWidgets('crossed on the way up: when, the price, the threshold and when it was set', (tester) async {
    final c = await pump(tester, at(8, 13));
    final a = await cross(tester, c, up: true);
    final threshold = a.rule.threshold;
    expect(find.byKey(const Key('gold-alert-screen')), findsOneWidget);
    expect(find.text('VÀNG VƯỢT NGƯỠNG · ${hhmm(a.shownAt)}'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('gold-alert-price'))).data, viNumber(a.price));
    expect(find.text('Mốc ${viPrice(threshold)} anh đặt lúc 08:13 · số liệu mẫu'), findsOneWidget);
    expect(find.text('Xem chart'), findsOneWidget);
    expect(find.text('Tắt báo'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('gold-alert-threshold'))).data, viPrice(threshold));
  });

  testWidgets('the chart runs from when the alert was set to now, with the threshold and both times', (tester) async {
    final c = await pump(tester, at(8, 13));
    final a = await cross(tester, c, up: true);
    final ch = chart(tester);
    final points = ch.points;
    expect(points.first.at, at(8, 10), reason: 'the price when it was set: the step at or before 08:13');
    expect(points[1].at.isAfter(a.rule.setAt), isTrue);
    expect(points.last.at, c.gold.points.last.at);
    expect(points.last.price, c.gold.last);
    expect(ch.threshold, a.rule.threshold);
    expect(ch.labels, isTrue);
    expect(ch.startLabel, '08:10');
    expect(ch.endLabel, hhmm(c.gold.points.last.at));
    final label = tester.getRect(find.byKey(const Key('gold-alert-threshold')));
    final box = tester.getRect(find.byType(LineChart));
    expect(label.left, lessThan(box.left + 20), reason: 'at the left end, away from where the price crosses');
    expect(box.contains(label.topLeft) && box.contains(label.bottomRight), isTrue);
  });

  testWidgets('"Xem chart" opens the gold chart; the alert is gone, the rule stays as fired', (tester) async {
    final c = await pump(tester, at(8, 13));
    await cross(tester, c, up: true);
    final primary = find.byKey(const Key('alert-primary'));
    expect(find.descendant(of: primary, matching: find.text('Xem chart')), findsOneWidget);
    await tester.tap(primary);
    await tester.pump();
    expect(c.alert, isNull);
    expect(c.screen, Screen.gold);
    expect(c.goldAlert!.fired, isTrue);
    expect(find.byKey(const Key('gold-alert-screen')), findsNothing);
  });

  testWidgets('"Tắt báo" clears the alert', (tester) async {
    final c = await pump(tester, at(8, 13));
    await cross(tester, c, up: true);
    final secondary = find.byKey(const Key('alert-secondary'));
    expect(find.descendant(of: secondary, matching: find.text('Tắt báo')), findsOneWidget);
    await tester.tap(secondary);
    await tester.pump();
    expect(c.alert, isNull);
    expect(c.goldAlert, isNull);
    expect(c.screen, Screen.home);
    expect(find.byKey(const Key('gold-alert-screen')), findsNothing);
  });

  testWidgets('crossed on the way down: "xuống dưới"', (tester) async {
    final c = await pump(tester, at(9, 41));
    final a = await cross(tester, c, up: false);
    expect(a.rule.above, isFalse);
    expect(find.text('VÀNG XUỐNG DƯỚI NGƯỠNG · ${hhmm(a.shownAt)}'), findsOneWidget);
    expect(find.textContaining('VÀNG VƯỢT'), findsNothing);
    expect(find.text('Mốc ${viPrice(a.rule.threshold)} anh đặt lúc 09:41 · số liệu mẫu'), findsOneWidget);
  });

  testWidgets('set within the latest step or on another day: the chart falls back to the whole day', (tester) async {
    // 08:15:00 sits on a step: no live point after it, so "since 08:15" is a single point.
    final now = at(8, 15);
    final c = await pump(
      tester,
      now,
      shown: GoldCrossedAlert(GoldAlert(threshold: 4150, above: true, setAt: now), 4150.2, now),
    );
    expect(chart(tester).points.length, c.gold.points.length);
    expect(chart(tester).startLabel, '00:00');

    final c2 = await pump(
      tester,
      now,
      shown: GoldCrossedAlert(
        GoldAlert(threshold: 4150, above: true, setAt: now.subtract(const Duration(days: 1))),
        4150.2,
        now,
      ),
    );
    expect(chart(tester).points.length, c2.gold.points.length);
  });

  test('chartPoints: from the step at or before the time it was set', () {
    final points = [for (var i = 0; i < 6; i++) PricePoint(at(8, 5 * i), 4100.0 + i)];
    expect(GoldAlertScreen.chartPoints(points, at(8, 13)).map((p) => p.at), [
      at(8, 10),
      at(8, 15),
      at(8, 20),
      at(8, 25),
    ]);
    expect(GoldAlertScreen.chartPoints(points, at(8, 10)).first.at, at(8, 10), reason: 'a step on the minute');
    expect(GoldAlertScreen.chartPoints(points, at(7)).length, 6, reason: 'set before the first point');
    expect(GoldAlertScreen.chartPoints(points, at(9)).length, 6, reason: 'set after the last point');
    expect(GoldAlertScreen.chartPoints(points.take(1).toList(), at(8)).length, 1);
  });

  for (final up in [true, false]) {
    testWidgets('layout (${up ? 'up' : 'down'}): left of the mic strip, nothing overlaps, big buttons, no overflow', (
      tester,
    ) async {
      final now = at(10, 45);
      // A threshold that is not a round number makes the longest meta line ("Mốc 4.146,4 ...").
      await pump(
        tester,
        now,
        shown: GoldCrossedAlert(GoldAlert(threshold: 4146.4, above: up, setAt: at(8, 13)), up ? 4146.6 : 4146.1, now),
      );
      expect(tester.takeException(), isNull);
      final screen = find.byKey(const Key('gold-alert-screen'));
      for (final e in find.descendant(of: screen, matching: find.byType(Text)).evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        expect(r.right, lessThanOrEqualTo(right), reason: '${(e.widget as Text).data}');
        expect(r.top, greaterThanOrEqualTo(0));
        expect(r.bottom, lessThanOrEqualTo(320));
      }
      final text = [
        tester.getRect(find.textContaining('VÀNG ')),
        tester.getRect(find.byKey(const Key('gold-alert-price'))),
        tester.getRect(find.text('Mốc 4.146,4 anh đặt lúc 08:13 · số liệu mẫu')),
      ];
      for (final r in text) {
        expect(r.width, lessThan(GoldAlertScreen.textWidth), reason: 'fits without being cut: $r');
      }
      final textBlock = text.reduce((a, b) => a.expandToInclude(b));
      final chartBox = tester.getRect(find.byType(LineChart));
      final buttons = [
        tester.getRect(find.byKey(const Key('alert-primary'))),
        tester.getRect(find.byKey(const Key('alert-secondary'))),
      ];
      expect(chartBox.right, lessThanOrEqualTo(right));
      expect(chartBox.width, greaterThan(300), reason: 'the chart keeps a readable width');
      expect(textBlock.overlaps(chartBox), isFalse, reason: 'text $textBlock, chart $chartBox');
      for (final b in buttons) {
        expect(b.height, greaterThanOrEqualTo(48));
        expect(b.right, lessThanOrEqualTo(right));
        expect(b.overlaps(chartBox), isFalse, reason: 'button $b, chart $chartBox');
        expect(b.overlaps(textBlock), isFalse);
      }
      expect(buttons[0].right, lessThanOrEqualTo(buttons[1].left), reason: '"Xem chart" first');
      final label = tester.getRect(find.byKey(const Key('gold-alert-threshold')));
      expect(
        chartBox.contains(label.topLeft) && chartBox.contains(label.bottomRight),
        isTrue,
        reason: 'threshold label $label inside the chart $chartBox',
      );
    });
  }
}
