import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/core/vi_format.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/ui/screens/gold.dart';
import 'package:near_app/ui/widgets/line_chart.dart';

import '../support/fakes.dart';
import '../support/fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  final day = DateTime(2026, 11, 16);

  Future<AppController> pump(WidgetTester tester, DateTime at) async {
    tester.view.physicalSize = const Size(1480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = AppController(
      clock: FakeClock(at),
      store: tempStore(),
      calendar: SampleCalendarSource(launchedAt: DateTime(at.year, at.month, at.day, 6)),
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
            builder: (context, _) => GoldScreen(c: c),
          ),
        ),
      ),
    );
    return c;
  }

  String signed(double v, {int decimals = 1}) => '${v < 0 ? '-' : '+'}${viNumber(v.abs(), decimals: decimals)}';

  testWidgets('price, change since midnight, high and low come from today\'s series', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 8, minutes: 10)));
    final g = c.gold;
    expect(find.text('VÀNG THẾ GIỚI · USD/OUNCE'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('gold-full-price'))).data, viNumber(g.last));
    expect(find.text('${signed(g.change)} (${signed(g.changePct, decimals: 2)}%) từ 0 giờ'), findsOneWidget);
    expect(find.text('Cao ${viNumber(g.high)} · Thấp ${viNumber(g.low)}'), findsOneWidget);
    expect(find.text('Số liệu mẫu'), findsOneWidget);
    expect(find.textContaining('Hôm qua'), findsNothing, reason: 'no comparison until asked');
  });

  testWidgets('"so với hôm qua": yesterday at the same time of day, and the difference', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 8, minutes: 12)));
    c.goldCompare = true;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, _) => SizedBox(width: 1480, height: 320, child: GoldScreen(c: c)),
      ),
    );
    final today = c.gold;
    final y = c.goldYesterday.points.firstWhere((p) => p.at.hour == 8 && p.at.minute == 10);
    expect(find.text('Hôm qua lúc này: ${viNumber(y.price)} · chênh ${signed(today.last - y.price)}'), findsOneWidget);
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.compare!.last.at, y.at, reason: 'yesterday cut at the same time of day (last whole step)');
    expect(chart.compare!.first.at, day.subtract(const Duration(days: 1)));
  });

  testWidgets('a price alert shows its threshold on the left and on the chart', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 8, minutes: 13)));
    c.run(const SetGoldAlert(4150));
    await tester.pump();
    final above = c.goldAlert!.above;
    expect(find.text('${above ? 'Báo khi vượt' : 'Báo khi xuống dưới'} 4.150'), findsOneWidget);
    expect(find.text('Còn cách ${viNumber((4150 - c.gold.last).abs())} đô'), findsOneWidget);
    expect(tester.widget<LineChart>(find.byType(LineChart)).threshold, 4150);
  });

  testWidgets('tap or drag on the chart reads the nearest point', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 8, minutes: 11)));
    final points = c.gold.points;
    final chart = find.byKey(const Key('gold-chart'));
    final rect = tester.getRect(chart);

    await tester.tapAt(rect.topLeft + const Offset(1, 60));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('gold-scrub-label'))).data,
      '00:00 · ${viNumber(points.first.price)}',
    );

    final x = rect.width * .5;
    final i = LineChart.indexAt(x, points.length, rect.width, yLabels: true);
    await tester.dragFrom(rect.topLeft + const Offset(40, 60), Offset(x - 40, 0));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('gold-scrub-label'))).data,
      '${hhmm(points[i].at)} · ${viNumber(points[i].price)}',
    );
  });

  testWidgets('nothing is laid out right of the mic and VI/EN strip', (tester) async {
    await pump(tester, day.add(const Duration(hours: 13)));
    for (final e in find.descendant(of: find.byKey(const Key('gold-screen')), matching: find.byType(Text)).evaluate()) {
      expect(
        tester.getRect(find.byWidget(e.widget)).right,
        lessThanOrEqualTo(1360),
        reason: '${(e.widget as Text).data}',
      );
    }
    expect(tester.getRect(find.byKey(const Key('gold-chart'))).right, lessThanOrEqualTo(1360));
  });
}
