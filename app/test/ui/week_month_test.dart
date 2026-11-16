import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/domain/day_plan.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/models.dart';
import 'package:near_app/ui/screens/month.dart';
import 'package:near_app/ui/screens/week.dart';

import '../support/fakes.dart';
import '../support/fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  final monday = DateTime(2026, 11, 16);

  /// A controller at [at] whose plan covers all of November (the controller itself fetches a narrower range).
  /// [before] changes the controller before the first frame.
  Future<AppController> pump(
    WidgetTester tester,
    DateTime at,
    Widget Function(AppController c) screen, {
    void Function(AppController c)? before,
  }) async {
    tester.view.physicalSize = const Size(1480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = SampleCalendarSource(launchedAt: monday.add(const Duration(hours: 6)));
    final c = AppController(
      clock: FakeClock(at),
      store: tempStore(),
      calendar: source,
      voice: FakeVoice(),
      heardHold: Duration.zero,
      log: (_) {},
    );
    await tester.runAsync(() async {
      await c.start(ticker: false);
      c.plan = DayPlan(await source.fetch(DateTime(2026, 11, 1), DateTime(2026, 12, 1)));
    });
    before?.call(c);
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, _) => SizedBox(
          width: 1480,
          height: 320,
          child: ListenableBuilder(listenable: c, builder: (context, _) => screen(c)),
        ),
      ),
    );
    return c;
  }

  double opacityOf(WidgetTester tester, Key key) =>
      tester.widget<Opacity>(find.descendant(of: find.byKey(key), matching: find.byType(Opacity)).first).opacity;

  group('helpers', () {
    test('short weekday, week range, free length, days left', () {
      expect(weekdayShort(DateTime(2026, 11, 19)), 'T5 19');
      expect(weekdayShort(DateTime(2026, 11, 22)), 'CN 22');
      expect(weekRange(DayPlan.weekOf(monday)), '16–22/11');
      expect(weekRange(DayPlan.weekOf(DateTime(2026, 12, 2))), '30/11–6/12');
      expect(shortDuration(const Duration(hours: 3, minutes: 45)), '3h45');
      expect(shortDuration(const Duration(hours: 2)), '2h');
      expect(shortDuration(const Duration(minutes: 45)), '45ph');
      expect(daysBetween(DateTime(2026, 11, 16, 23, 59), DateTime(2026, 11, 20, 0, 1)), 4);
      expect(daysBetween(DateTime(2026, 11, 30, 9), DateTime(2026, 12, 1, 8)), 1, reason: 'across a month end');
      expect(daysLeftVi(4), 'Còn 4 ngày');
      expect(daysLeftVi(1), 'Ngày mai');
      expect(daysLeftVi(0), 'Hôm nay');
      expect(daysLeftVi(-2), 'Đã qua 2 ngày');
      expect(MonthScreen.monthOf(DateTime(2026, 11, 16)), hasLength(30));
      expect(MonthScreen.monthOf(DateTime(2026, 12, 31)).last, DateTime(2026, 12, 31));
      expect(MonthScreen.monthOf(DateTime(2028, 2, 3)), hasLength(29), reason: 'leap year');
    });
  });

  group('week', () {
    testWidgets('seven day cards left of the mic strip, today highlighted, a tap opens the day', (tester) async {
      final opened = <DateTime>[];
      await pump(tester, monday.add(const Duration(hours: 9)), (c) => WeekScreen(c: c, onOpenDay: opened.add));
      expect(find.text('TUẦN NÀY · 16–22/11'), findsOneWidget);
      expect(find.text('16 cuộc họp · 1 hạn chót'), findsOneWidget);
      expect(find.text('T2 16 · HÔM NAY'), findsOneWidget);
      expect(find.text('Kế hoạch quý'), findsOneWidget);
      expect(find.text('Hạn gửi báo giá'), findsOneWidget);
      expect(find.text('Đá bóng'), findsOneWidget);
      expect(find.text('Trống'), findsOneWidget, reason: 'Saturday');
      for (var w = DateTime.monday; w <= DateTime.sunday; w++) {
        final r = tester.getRect(find.byKey(ValueKey('week-day-$w')));
        expect(r.right, lessThanOrEqualTo(1360), reason: 'weekday $w');
        expect(r.bottom, lessThanOrEqualTo(320));
        expect(opacityOf(tester, ValueKey('week-day-$w')), 1);
      }
      expect(tester.takeException(), isNull, reason: 'no overflow, even with 7 rows on Monday');

      await tester.tap(find.byKey(const ValueKey('week-day-${DateTime.thursday}')));
      expect(opened, [DateTime(2026, 11, 19)]);
    });

    testWidgets('"thứ năm rảnh lúc nào": Thursday shows its free slots, the other days fade', (tester) async {
      final c = await pump(tester, monday.add(const Duration(hours: 9)), (c) => WeekScreen(c: c, onOpenDay: (_) {}));
      c.run(const FreeSlots(DateTime.thursday));
      await tester.pump();
      expect(c.screen, Screen.week);
      expect(find.text('THỨ NĂM 19/11 RẢNH LÚC NÀO'), findsOneWidget);
      expect(find.text('2 khoảng rảnh · tổng 7 giờ 15 phút'), findsOneWidget);
      expect(find.text('Rảnh tới 13:00'), findsOneWidget);
      expect(find.text('3h45'), findsOneWidget);
      expect(find.text('Rảnh tới 18:00'), findsOneWidget);
      expect(find.text('3h30'), findsOneWidget);
      expect(opacityOf(tester, const ValueKey('week-day-${DateTime.thursday}')), 1);
      expect(opacityOf(tester, const ValueKey('week-day-${DateTime.monday}')), .3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a busy day with free slots too folds the rest into "+N nữa" without overflowing', (tester) async {
      final c = await pump(tester, monday.add(const Duration(hours: 9)), (c) => WeekScreen(c: c, onOpenDay: (_) {}));
      c.run(const FreeSlots(DateTime.monday));
      await tester.pump();
      expect(find.textContaining('nữa'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('day', () {
    testWidgets('Thursday opened from the week: meetings, free time and the longest free stretch', (tester) async {
      await pump(
        tester,
        monday.add(const Duration(hours: 9)),
        (c) => DayScreen(c: c),
        before: (c) => c.openDay = DateTime(2026, 11, 19),
      );
      expect(find.text('XEM NGÀY'), findsOneWidget);
      expect(find.text('Thứ Năm 19/11'), findsOneWidget);
      expect(find.text('2 cuộc họp · rảnh 7 giờ 15 phút trong giờ làm'), findsOneWidget);
      expect(find.text('KHOẢNG RẢNH DÀI NHẤT'), findsOneWidget);
      expect(find.text('09:15 – 13:00'), findsOneWidget);
      expect(find.text('3 giờ 45 phút'), findsOneWidget);
      expect(find.text('Kế hoạch quý'), findsOneWidget, reason: 'on the timeline');
      expect(tester.takeException(), isNull);
    });

    testWidgets('no day opened: today; a fully booked day says so', (tester) async {
      await pump(
        tester,
        monday.add(const Duration(hours: 9)),
        (c) => DayScreen(c: c),
        before: (c) => c.plan = DayPlan([ev('all', 'Hội nghị', monday.add(const Duration(hours: 8)), 11 * 60)]),
      );
      expect(find.text('XEM NGÀY · HÔM NAY'), findsOneWidget);
      expect(find.text('KÍN LỊCH TRONG GIỜ LÀM'), findsOneWidget);
      expect(find.text('Không còn chỗ trống'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('month', () {
    testWidgets('30 day cells with meeting bars and the dates to remember', (tester) async {
      await pump(tester, monday.add(const Duration(hours: 9)), (c) => MonthScreen(c: c));
      expect(find.text('THÁNG 11 · 2026'), findsOneWidget);
      expect(find.byKey(const ValueKey('month-day-30')), findsOneWidget);
      expect(find.byKey(const ValueKey('month-day-31')), findsNothing);
      expect(tester.getRect(find.byKey(const ValueKey('month-day-30'))).right, lessThanOrEqualTo(1360));
      expect(find.text('25 Release 1.2'), findsOneWidget);
      expect(find.text('28 Sinh nhật mẹ'), findsOneWidget);
      expect(find.text('20 Hạn gửi báo giá'), findsOneWidget);
      expect(opacityOf(tester, const ValueKey('month-day-13')), .4, reason: 'past');
      expect(opacityOf(tester, const ValueKey('month-day-16')), 1, reason: 'today');
      double bar(int day) => tester.getSize(find.byKey(ValueKey('bar-$day'))).height;
      expect(bar(18), MonthScreen.maxBar, reason: 'Wednesdays are the busiest (3 h 15)');
      expect(bar(21), 0, reason: 'Saturday');
      expect(bar(19), closeTo(MonthScreen.maxBar * 105 / 195, .01), reason: 'Thursday 1 h 45 of 3 h 15');
      expect(find.byKey(const ValueKey('span-16')), findsNothing, reason: 'no countdown asked');
      expect(tester.takeException(), isNull);
    });

    testWidgets('"còn mấy ngày tới hạn gửi báo giá": header counts down, the days up to it are tinted', (tester) async {
      final c = await pump(tester, monday.add(const Duration(hours: 9)), (c) => MonthScreen(c: c));
      c.run(const DaysUntil('báo giá'));
      await tester.pump();
      expect(c.screen, Screen.month);
      expect(c.countdownTo?.title, SampleCalendarSource.deadlineTitle);
      expect(find.text('HẠN GỬI BÁO GIÁ'), findsOneWidget);
      expect(find.text('Còn 4 ngày · Thứ Sáu 20/11'), findsOneWidget);
      for (var d = 16; d <= 20; d++) {
        expect(find.byKey(ValueKey('span-$d')), findsOneWidget, reason: '$d');
      }
      expect(find.byKey(const ValueKey('span-15')), findsNothing);
      expect(find.byKey(const ValueKey('span-21')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a deadline next month shows that month', (tester) async {
      await pump(
        tester,
        DateTime(2026, 11, 30, 9),
        (c) => MonthScreen(c: c),
        before: (c) => c.countdownTo = CalendarEvent(
          id: 'x',
          title: 'Nộp thuế',
          start: DateTime(2026, 12, 3, 10),
          end: DateTime(2026, 12, 3, 10),
          kind: EventKind.deadline,
        ),
      );
      expect(find.text('NỘP THUẾ'), findsOneWidget);
      expect(find.text('Còn 3 ngày · Thứ Năm 3/12'), findsOneWidget);
      expect(find.byKey(const ValueKey('month-day-31')), findsOneWidget, reason: 'December');
      for (var d = 1; d <= 3; d++) {
        expect(find.byKey(ValueKey('span-$d')), findsOneWidget, reason: 'December $d is before the deadline');
      }
      expect(find.byKey(const ValueKey('span-4')), findsNothing);
      expect(opacityOf(tester, const ValueKey('month-day-1')), 1, reason: 'still ahead of today');
      expect(tester.takeException(), isNull);
    });
  });
}
