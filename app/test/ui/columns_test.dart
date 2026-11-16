import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/core/vi_format.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/ui/screens/columns.dart';

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
            builder: (context, _) => ColumnsScreen(c: c),
          ),
        ),
      ),
    );
    return c;
  }

  test('viNumber uses dots for thousands and a comma for decimals', () {
    expect(viNumber(4146.2), '4.146,2');
    expect(viNumber(33.8), '33,8');
    expect(viNumber(0.82, decimals: 2), '0,82');
    expect(viNumber(1234567.25, decimals: 2), '1.234.567,25');
    expect(viNumber(-26.5), '-26,5');
    expect(viNumber(999.96), '1.000,0');
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

  testWidgets('a running timer counts down in its column', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 31)));
    c.run(const StartTimer(Duration(minutes: 45), focus: false));
    await tester.pump();
    expect(find.text('45:00'), findsOneWidget);
    expect(find.text('Kết thúc 14:16'), findsOneWidget);
    expect(find.text('HẸN GIỜ'), findsOneWidget);
    expect(find.text('Chưa chạy'), findsNothing);
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

  testWidgets('hold a column to zoom it; the others shrink to a glanceable edge; tap to zoom back', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 13, minutes: 30)));
    c.run(const StartTimer(Duration(minutes: 45), focus: false));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('column-touch-gold')));
    await tester.pump();
    final gold = tester.getRect(find.byKey(const Key('column-gold')));
    expect(gold.width, greaterThan(900), reason: 'the zoomed column takes the room');
    expect(gold.right, lessThanOrEqualTo(1360));
    expect(find.byKey(const Key('column-calendar')), findsNothing);
    expect(find.byKey(const Key('column-edge-calendar')), findsOneWidget);
    expect(find.text('GIỜ'), findsOneWidget);
    expect(find.byKey(const Key('column-edge-timer')), findsOneWidget);
    expect(find.text('45:00'), findsOneWidget, reason: 'the shrunk timer still counts down');
    expect(c.screen, Screen.home, reason: 'a hold zooms; it does not open the chart');
    expect(tester.takeException(), isNull, reason: 'no overflow');

    await tester.tap(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    expect(find.byKey(const Key('column-calendar')), findsOneWidget, reason: 'tap anywhere zooms back');
    expect(find.byKey(const Key('column-edge-timer')), findsNothing);
    expect(c.screen, Screen.home, reason: 'the tap only zoomed back');
  });

  testWidgets('hold the zoomed column again to zoom back', (tester) async {
    await pump(tester, day.add(const Duration(hours: 9)));
    await tester.longPress(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    expect(find.byKey(const Key('column-edge-gold')), findsOneWidget);
    await tester.longPress(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    expect(find.byKey(const Key('column-edge-gold')), findsNothing);
    expect(find.byKey(const Key('column-gold')), findsOneWidget);
  });

  testWidgets('a tap on the gold column opens the chart; taps on the others do not', (tester) async {
    final c = await pump(tester, day.add(const Duration(hours: 9)));
    await tester.tap(find.byKey(const Key('column-touch-calendar')));
    await tester.tap(find.byKey(const Key('column-touch-timer')));
    await tester.pump();
    expect(c.screen, Screen.home);
    await tester.tap(find.byKey(const Key('column-touch-gold')));
    await tester.pump();
    expect(c.screen, Screen.gold);
    expect(c.goldCompare, isFalse);
  });
}
