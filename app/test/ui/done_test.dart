import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/ui/theme.dart' show micZoneWidth, stripWidth;

import '../support/fonts.dart';
import '../support/strip.dart';

void main() {
  setUpAll(loadAppFonts);
  final monday = DateTime(2026, 11, 16);
  final at = monday.add(const Duration(hours: 14, minutes: 35));
  final launch = monday.add(const Duration(hours: 6));
  const micLeft = stripWidth - micZoneWidth;

  /// Every rect of [keys] stays left of the mic zone, and is a big enough touch target.
  void checkButtons(WidgetTester tester, List<String> keys) {
    for (final k in keys) {
      final r = tester.getRect(find.byKey(Key(k)));
      expect(r.right, lessThanOrEqualTo(micLeft), reason: '$k right of the mic zone edge');
      expect(r.height, greaterThanOrEqualTo(48), reason: '$k height');
    }
  }

  testWidgets('choice screen: what was heard, two big options left of the mic, "Nói lại"', (tester) async {
    final h = await StripHarness.pump(tester, at: at, launchedAt: launch, columns: true);
    await h.say('xong việc gửi báo cáo cho khách');
    expect(find.text('MÁY NGHE ĐƯỢC'), findsOneWidget);
    expect(find.text('“Xong việc gửi báo cáo cho khách”'), findsOneWidget);
    expect(find.text('CHƯA CHẮC · VIỆC NÀO ĐÃ XONG?'), findsOneWidget);
    expect(find.text('Gửi báo giá cho khách'), findsOneWidget);
    expect(find.text('Hạn thứ Sáu 20/11'), findsOneWidget);
    expect(find.text('Gửi báo cáo tuần'), findsOneWidget);
    expect(find.text('Hạn thứ Năm 19/11'), findsOneWidget);
    expect(find.byKey(const Key('column-gold')), findsNothing, reason: 'whole strip, on the columns too');
    expect(find.byKey(const Key('mic')), findsOneWidget);
    checkButtons(tester, ['done-option-0', 'done-option-1', 'done-retry']);
    final o0 = tester.getRect(find.byKey(const Key('done-option-0')));
    final o1 = tester.getRect(find.byKey(const Key('done-option-1')));
    expect(o0.bottom, lessThanOrEqualTo(o1.top), reason: 'stacked, not overlapping');
    final heard = tester.getRect(find.text('“Xong việc gửi báo cáo cho khách”'));
    expect(heard.right, lessThan(o0.left), reason: 'the heard text stays clear of the options and their touch slop');
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Nói lại'));
    await h.settle();
    expect(find.text('ĐANG NGHE'), findsOneWidget);
    expect(h.c.doneChoice, isNull);
  });

  testWidgets('choice: a tap landing 38 px left of the option still picks it', (tester) async {
    final h = await StripHarness.pump(tester, at: at, launchedAt: launch);
    await h.say('xong việc gửi báo cáo cho khách');
    final title = tester.getRect(find.text('Gửi báo cáo tuần'));
    final box = tester.getRect(find.byKey(const Key('done-option-1')));
    await tester.tapAt(Offset(box.left + 2, title.center.dy));
    await h.settle();
    expect(h.c.doneUndo?.task.title, 'Gửi báo cáo tuần');
  });

  testWidgets('done screen: check, title, what is left, timeline, "Hoàn tác" with an 8 s bar left of the mic',
      (tester) async {
    final h = await StripHarness.pump(tester, at: at, launchedAt: launch, columns: true);
    await h.say('xong việc gửi báo giá cho khách');
    expect(find.text('ĐÃ ĐÁNH DẤU XONG'), findsOneWidget);
    expect(find.text('Gửi báo giá cho khách'), findsOneWidget);
    expect(find.text('Còn lại: Gửi báo cáo tuần · Hạn thứ Năm 19/11'), findsOneWidget);
    expect(find.text('Hoàn tác'), findsOneWidget);
    expect(find.text('Tự ẩn sau 8 giây'), findsOneWidget);
    expect(find.text('BÂY GIỜ'), findsOneWidget, reason: 'the timeline');
    expect(find.byKey(const Key('column-gold')), findsNothing);
    checkButtons(tester, ['undo']);
    final undo = tester.getRect(find.text('Hoàn tác'));
    expect(undo.bottom, lessThanOrEqualTo(212), reason: 'above the timeline');
    expect(tester.getRect(find.byKey(const Key('done-title'))).right, lessThan(tester.getRect(find.byKey(const Key('undo'))).left));
    double fill() => tester.getSize(find.byKey(const Key('undo-bar-fill'))).width;
    expect(fill(), closeTo(250, .5), reason: 'full when just marked');
    await h.run(const Duration(seconds: 4));
    expect(fill(), closeTo(125, .5), reason: 'half after 4 of 8 seconds');
    expect(tester.takeException(), isNull);
    await h.run(const Duration(seconds: 3));
    expect(find.text('ĐÃ ĐÁNH DẤU XONG'), findsOneWidget, reason: 'still there at 7 s');
    await h.run(const Duration(seconds: 1));
    expect(find.text('ĐÃ ĐÁNH DẤU XONG'), findsNothing);
    expect(find.byKey(const Key('column-gold')), findsOneWidget, reason: 'the columns come back');
  });

  testWidgets('long Vietnamese titles are cut, not overflowing, on both screens', (tester) async {
    final h = await StripHarness.pump(tester, at: at, launchedAt: launch);
    const long = 'Chuẩn bị tài liệu thuyết trình quý bốn cho buổi họp hội đồng quản trị mở rộng vào cuối tuần sau';
    h.c.run(const AddNote(long));
    h.c.run(const AddNote('$long nữa'));
    h.c.run(const MarkDone('chuẩn bị tài liệu thuyết trình quý bốn cho buổi họp hội đồng quản trị',
        heard: 'Xong việc chuẩn bị tài liệu thuyết trình quý bốn cho buổi họp hội đồng quản trị mở rộng vào cuối tuần sau'));
    await h.settle();
    expect(h.c.doneChoice, isNotNull);
    expect(tester.takeException(), isNull);
    checkButtons(tester, ['done-option-0', 'done-option-1']);
    await tester.tap(find.byKey(const Key('done-option-0')));
    await h.settle();
    expect(find.text('ĐÃ ĐÁNH DẤU XONG'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(AppController.undoFor, const Duration(seconds: 8));
  });
}
