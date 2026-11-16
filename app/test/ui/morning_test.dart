import 'dart:convert';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/data/local_store.dart';
import 'package:near_app/domain/models.dart';
import 'package:near_app/ui/screens/morning.dart';
import 'package:near_app/ui/theme.dart' show micZoneWidth, stripWidth;
import 'package:near_app/ui/widgets/timeline.dart';

import '../support/fakes.dart';
import '../support/fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  final monday = DateTime(2026, 11, 16);
  DateTime mon(int h, [int m = 0]) => monday.add(Duration(hours: h, minutes: m));
  DateTime tue(int h, [int m = 0]) => monday.add(Duration(days: 1, hours: h, minutes: m));
  const right = stripWidth - micZoneWidth;

  Note note(String id, String text, {DateTime? done}) => Note(id: id, text: text, createdAt: mon(14), doneAt: done);

  /// The brief at [now] with [state] saved before the start; Tuesday is the sample calendar's second day.
  Future<AppController> pump(WidgetTester tester, DateTime now, StoredState state) async {
    tester.view.physicalSize = const Size(1480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = tempStore();
    store.file.writeAsStringSync(jsonEncode(state.toJson()));
    final c = AppController(
      clock: FakeClock(now),
      store: store,
      calendar: SampleCalendarSource(launchedAt: mon(6)),
      voice: FakeVoice(),
      heardHold: Duration.zero,
      log: (_) {},
    );
    await tester.runAsync(() => c.start(ticker: false));
    await tester.pumpWidget(WidgetsApp(
      color: const Color(0xFF000000),
      builder: (context, _) => SizedBox(
        width: 1480,
        height: 320,
        child: ListenableBuilder(listenable: c, builder: (context, _) => MorningBriefScreen(c: c)),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    return c;
  }

  /// No overflow; every text left of the strip's edge, and left of the mic and VI/EN zone above y 200.
  void checkLayout(WidgetTester tester, String reason) {
    expect(tester.takeException(), isNull, reason: '$reason: no overflow');
    for (final e in find.descendant(of: find.byType(MorningBriefScreen), matching: find.byType(RichText)).evaluate()) {
      final box = e.renderObject! as RenderBox;
      final r = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
      final text = (e.widget as RichText).text.toPlainText();
      expect(r.left, greaterThanOrEqualTo(0), reason: '$reason: "$text"');
      if (r.top < 200) expect(r.right, lessThanOrEqualTo(right), reason: '$reason: "$text" clear of the mic zone');
    }
  }

  bool cut(WidgetTester tester, String text) => tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

  testWidgets('the demo at 08:25: greeting, today, the longest free stretch, yesterday\'s two open items, the Sync lit',
      (tester) async {
    final c = await pump(
      tester,
      tue(8, 25),
      StoredState(notes: [
        note('quote', 'Gửi báo giá cho khách trước thứ sáu'),
        note('milk', 'Mua sữa và trứng trên đường về'),
        note('room', 'Đặt phòng họp thứ năm', done: mon(17, 55)),
      ], reminders: [
        Reminder(id: 'lan', text: 'Gọi cho chị Lan', at: mon(15), createdAt: mon(14, 12), doneAt: mon(15)),
      ]),
    );
    expect(c.screen, Screen.brief, reason: 'the first start this morning');
    for (final t in ['CHÀO BUỔI SÁNG', '08:25', 'Thứ Ba 17/11', 'HÔM NAY', '3 cuộc họp', 'Rảnh dài nhất 10:00 – 13:30',
      '2 VIỆC TỪ HÔM QUA', 'Gửi báo giá cho khách trước thứ sáu', 'Mua sữa và trứng trên đường về']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Đặt phòng họp thứ năm'), findsNothing, reason: 'done');
    expect(find.text('Gọi cho chị Lan'), findsNothing, reason: 'done');
    expect(cut(tester, 'Rảnh dài nhất 10:00 – 13:30'), isFalse, reason: 'fits the middle column');
    expect(tester.widget<Timeline>(find.byType(Timeline)).highlightId, 'm0', reason: 'Sync với team design');
    checkLayout(tester, '08:25');
  });

  testWidgets('nothing carried over: no list, the rest stays', (tester) async {
    await pump(tester, tue(8, 25), StoredState(notes: [note('room', 'Đặt phòng họp thứ năm', done: mon(17))]));
    expect(find.textContaining('VIỆC TỪ HÔM QUA'), findsNothing);
    expect(find.byKey(const Key('brief-list')), findsNothing);
    expect(find.text('3 cuộc họp'), findsOneWidget);
    expect(find.text('CHÀO BUỔI SÁNG'), findsOneWidget);
    checkLayout(tester, 'empty');
  });

  testWidgets('four items fit; more fold into "+N việc nữa"; long text is cut, above the timeline', (tester) async {
    const long = 'Chuẩn bị tài liệu thuyết trình quý bốn cho buổi họp hội đồng quản trị mở rộng vào cuối tuần sau';
    await pump(tester, tue(8, 25), StoredState(notes: [for (var i = 0; i < 4; i++) note('n$i', '$long $i')]));
    expect(find.text('4 VIỆC TỪ HÔM QUA'), findsOneWidget);
    expect(find.textContaining('việc nữa'), findsNothing);
    expect(find.text('$long 3'), findsOneWidget);
    checkLayout(tester, 'four');

    await pump(tester, tue(8, 25), StoredState(notes: [for (var i = 0; i < 6; i++) note('n$i', '$long $i')]));
    expect(find.text('6 VIỆC TỪ HÔM QUA'), findsOneWidget);
    expect(find.text('+3 việc nữa'), findsOneWidget);
    expect(find.text('$long 2'), findsOneWidget);
    expect(find.text('$long 3'), findsNothing);
    expect(cut(tester, '$long 0'), isTrue, reason: 'one line with an ellipsis');
    final list = tester.getRect(find.byKey(const Key('brief-list')));
    expect(list.right, lessThanOrEqualTo(right));
    expect(list.bottom, lessThanOrEqualTo(212), reason: 'above the timeline');
    checkLayout(tester, 'six');
  });

  testWidgets('a long date and a day without meetings still fit', (tester) async {
    final c = await pump(tester, DateTime(2026, 11, 29, 8, 25), StoredState());
    expect(find.text('Chủ Nhật 29/11'), findsOneWidget);
    expect(find.text('Không có họp'), findsOneWidget);
    expect(c.morningBrief.meetings, 0);
    checkLayout(tester, 'sunday');
  });

  testWidgets('a tap anywhere goes back home', (tester) async {
    final c = await pump(tester, tue(8, 25), StoredState(notes: [note('quote', 'Gửi báo giá')]));
    await tester.tapAt(const Offset(600, 120));
    await tester.pump();
    expect(c.screen, Screen.home);
  });
}
