import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/core/vi_format.dart';
import 'package:near_app/data/fx_source.dart';
import 'package:near_app/data/price_source.dart';
import 'package:near_app/ui/screens/fx_panel.dart';
import 'package:near_app/ui/theme.dart';
import 'package:near_app/ui/widgets/line_chart.dart';

import '../support/fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  final day = DateTime(2026, 11, 16);

  /// 31 days from 17/10 to 16/11: 26.310 rising to 26.373 yesterday and 26.385 today; the high is [high] on day 15.
  PriceSeries series({double today = 26385, double high = 26392}) => PriceSeries([
    for (var k = 0; k <= 30; k++)
      PricePoint(DateTime(day.year, day.month, day.day - (30 - k)), switch (k) {
        30 => today,
        29 => 26373,
        15 => high,
        _ => 26310 + k * 2,
      }),
  ]);

  /// Lays [child] out alone in a [width] x 320 view, like one column of the strip.
  Future<void> pumpAt(WidgetTester tester, double width, Widget child) async {
    tester.view.physicalSize = Size(width, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, _) => SizedBox(width: width, height: 320, child: child),
      ),
    );
  }

  group('FxPanel', () {
    testWidgets('rate, change since yesterday, sample tag and the first and last dates', (tester) async {
      await pumpAt(tester, 453, FxPanel(series: series()));
      expect(find.text('ĐÔ LA MỸ · USD/VND'), findsOneWidget);
      expect(find.text('Số liệu mẫu'), findsOneWidget);
      expect(tester.getRect(find.text('Số liệu mẫu')).right, closeTo(453 - 32, 1), reason: 'at the right, like gold');
      expect(tester.widget<Text>(find.byKey(const Key('fx-price'))).data, '26.385');
      final change = tester.widget<Text>(find.text('+12 so với hôm qua · bán ra'));
      expect(change.style!.color, Ink.cool, reason: 'up is cool, like gold');
      expect(find.text('17/10'), findsOneWidget);
      expect(find.text('16/11'), findsOneWidget);
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.points, hasLength(31));
      expect(chart.xTicks, isNull, reason: 'the column shows only the first and last dates');
    });

    testWidgets('a drop shows a minus sign in the hot colour', (tester) async {
      await pumpAt(tester, 453, FxPanel(series: series(today: 26368)));
      final change = tester.widget<Text>(find.text('-5 so với hôm qua · bán ra'));
      expect(change.style!.color, Ink.hot);
    });

    for (final width in const [400.0, 453.0, 480.0]) {
      testWidgets('lays out at $width x 320 without overflow', (tester) async {
        await pumpAt(tester, width, FxPanel(series: const SampleFxSource().usdVnd(day)));
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(FxPanel)), Size(width, 320));
        final price = tester.getRect(find.byKey(const Key('fx-price')));
        expect(price.right, lessThanOrEqualTo(width));
        expect(tester.getRect(find.byType(LineChart)).bottom, lessThanOrEqualTo(320));
      });
    }
  });

  group('FxZoom', () {
    testWidgets('eyebrow, header line and dates under days 0/10/20/30', (tester) async {
      await pumpAt(tester, 1000, FxZoom(series: series()));
      expect(find.text('ĐÔ LA MỸ · USD/VND · BÁN RA · 30 NGÀY'), findsOneWidget);
      expect(tester.getRect(find.text('Số liệu mẫu')).right, closeTo(1000 - 34, 1));
      expect(tester.widget<Text>(find.byKey(const Key('fx-zoom-price'))).data, '26.385');
      expect(
        tester.widget<Text>(find.byKey(const Key('fx-zoom-change'))).textSpan!.toPlainText(),
        '+12 so với hôm qua · +75 trong 30 ngày · cao nhất 26.392',
      );
      for (final d in const ['17/10', '27/10', '06/11', '16/11']) {
        expect(find.text(d), findsOneWidget, reason: d);
      }
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.yLabels, isTrue);
      expect(chart.xTicks!.map((t) => t.$1), [0, 10, 20, 30]);
    });

    testWidgets('the dates sit under their points', (tester) async {
      await pumpAt(tester, 1000, FxZoom(series: series()));
      final chart = tester.getRect(find.byType(LineChart));
      double xOf(int i) => chart.left + LineChart.xOf(i, 31, chart.width, yLabels: true);
      expect(tester.getRect(find.text('17/10')).left, closeTo(xOf(0), 1));
      expect(tester.getRect(find.text('27/10')).center.dx, closeTo(xOf(10), 1));
      expect(tester.getRect(find.text('06/11')).center.dx, closeTo(xOf(20), 1));
      expect(tester.getRect(find.text('16/11')).right, closeTo(xOf(30), 1));
    });

    test('y ticks are three to six round rates around the data, any day', () {
      for (var d = 0; d < 120; d++) {
        final s = const SampleFxSource().usdVnd(day.add(Duration(days: d)));
        final ticks = FxZoom.yTicksFor(s);
        expect(ticks.length, inInclusiveRange(3, 6), reason: 'day $d: $ticks');
        final step = ticks[1] - ticks[0];
        expect(const [10.0, 20.0, 50.0], contains(step), reason: 'day $d');
        for (final t in ticks) {
          expect(t % step, 0, reason: '$t is a multiple of $step');
          expect(t, inInclusiveRange(s.low - 20, s.high + 20));
        }
      }
      expect(
        FxZoom.yTicksFor(PriceSeries([PricePoint(day, 26385)])),
        isNotEmpty,
        reason: 'a flat line still has ticks',
      );
    });

    test('x ticks: first, last and two evenly between', () {
      expect(FxZoom.xTickIndices(31), [0, 10, 20, 30]);
      expect(FxZoom.xTickIndices(2), [0, 1]);
      expect(FxZoom.xTickIndices(1), [0]);
    });

    testWidgets('a drop shows a minus sign in the hot colour', (tester) async {
      await pumpAt(tester, 1000, FxZoom(series: series(today: 26368)));
      final text = tester.widget<Text>(find.byKey(const Key('fx-zoom-change'))).textSpan!;
      expect(text.toPlainText(), startsWith('-5 so với hôm qua · +58 trong 30 ngày'));
      final first = (text as TextSpan).children!.first as TextSpan;
      expect(first.style!.color, Ink.hot);
    });

    for (final width in const [960.0, 1000.0, 1094.0]) {
      testWidgets('lays out at $width x 320 without overflow', (tester) async {
        await pumpAt(tester, width, FxZoom(series: const SampleFxSource().usdVnd(day)));
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(FxZoom)), Size(width, 320));
        expect(tester.getRect(find.byType(LineChart)).bottom, lessThanOrEqualTo(320));
      });
    }
  });

  group('FxRail', () {
    testWidgets('label, rate and change since yesterday', (tester) async {
      await pumpAt(tester, 132, FxRail(series: series()));
      expect(find.text('USD/VND'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('fx-rail-price'))).data, '26.385');
      expect(tester.widget<Text>(find.text('+12 hôm qua')).style!.color, Ink.cool);
    });

    for (final width in const [130.0, 132.0, 230.0]) {
      testWidgets('lays out at $width x 320 without overflow', (tester) async {
        await pumpAt(tester, width, FxRail(series: const SampleFxSource().usdVnd(day)));
        expect(tester.takeException(), isNull);
        final price = tester.getRect(find.byKey(const Key('fx-rail-price')));
        expect(price.left, greaterThanOrEqualTo(0));
        expect(price.right, lessThanOrEqualTo(width));
      });
    }
  });

  group('LineChart.niceTicks', () {
    test('steps of 1, 2 or 5 times a power of ten, inside the range', () {
      expect(LineChart.niceTicks(26290, 26405, 4), [26300, 26350, 26400]);
      expect(LineChart.niceTicks(26310, 26390, 4), [26320, 26340, 26360, 26380]);
      expect(LineChart.niceTicks(0, 1, 4), [0, .5, 1]);
    });

    test('a step that would leave fewer than count - 1 values falls back to the next smaller one', () {
      // Step 50 is the first above (26400.4 - 26301.6) / 4 but only 26.350 and 26.400 fit; step 20 gives five.
      expect(LineChart.niceTicks(26301.6, 26400.4, 4), [26320, 26340, 26360, 26380, 26400]);
      expect(LineChart.niceTicks(1.2, 1.9, 1), [1.5], reason: 'count 1 keeps a single value');
    });

    test('empty for an empty or reversed range', () {
      expect(LineChart.niceTicks(5, 5, 4), isEmpty);
      expect(LineChart.niceTicks(6, 5, 4), isEmpty);
    });
  });

  test('viNumber with no decimals groups thousands with a dot', () {
    expect(viNumber(26385, decimals: 0), '26.385');
  });
}
