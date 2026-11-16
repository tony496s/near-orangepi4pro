import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/ui/theme.dart' show micZoneWidth, stripWidth;
import 'package:near_app/voice/voice_client.dart';

import '../support/fonts.dart';
import '../support/strip.dart';

void main() {
  setUpAll(loadAppFonts);
  final day = DateTime(2026, 11, 16);
  DateTime at(int h, [int m = 0]) => day.add(Duration(hours: h, minutes: m));

  testWidgets('day strip: clock, date, what is next and the timeline', (tester) async {
    await StripHarness.pump(tester, at: at(8, 52));
    expect(find.text('08:52'), findsOneWidget);
    expect(find.text('THỨ HAI · 16 THÁNG MƯỜI MỘT'), findsOneWidget);
    expect(find.text('TIẾP THEO'), findsOneWidget);
    expect(find.text('Họp đứng'), findsWidgets);
    expect(find.text('09:00 · còn 8 phút · Phòng 3'), findsOneWidget);
    expect(find.text('BÂY GIỜ'), findsOneWidget);
    expect(find.text('Họp thiết kế'), findsOneWidget, reason: 'on the timeline');
  });

  testWidgets('mic button and long press both start listening; a tap on the overlay finishes', (tester) async {
    final h = await StripHarness.pump(tester, at: at(9, 20));
    await tester.tap(find.byKey(const Key('mic')));
    await h.settle();
    expect(find.text('ĐANG NGHE'), findsOneWidget);
    expect(find.text('Ngừng nói là tự gửi · chạm để gửi ngay'), findsOneWidget);
    expect(h.voice.sent.last, 'listen l1');
    await tester.tap(find.byKey(const Key('listening')));
    await h.settle();
    expect(h.voice.sent.last, 'finish');
    expect(find.text('ĐANG HIỂU…'), findsOneWidget);
    h.voice.emit(const VoiceTimeout('l1'));
    await h.settle();
    expect(find.text('ĐANG HIỂU…'), findsNothing, reason: 'nothing was said: the overlay just closes');

    await tester.longPressAt(const Offset(300, 190));
    await h.settle();
    expect(find.text('ĐANG NGHE'), findsOneWidget);
    expect(h.voice.sent.last, 'listen l2');
  });

  testWidgets('mic: taps that land left of the circle, as measured on the board, still start listening', (tester) async {
    final h = await StripHarness.pump(tester, at: at(9, 20));
    expect(tester.getRect(find.byKey(const Key('mic-circle'))), const Rect.fromLTWH(1392, 22, 64, 64),
        reason: 'the circle is drawn where it was');
    var n = 0;
    // Three real taps on the board (16/11) missed the 64 px circle on its left; the last point is the zone's far corner.
    for (final p in const [Offset(1381, 38), Offset(1390, 36), Offset(1384, 47), Offset(1362, 96)]) {
      await tester.tapAt(p);
      await h.settle();
      expect(h.voice.sent.lastOrNull, 'listen l${++n}', reason: 'tap at $p');
      h.c.cancelTalk();
      await h.settle();
    }
    await tester.tapAt(const Offset(1350, 60));
    await h.settle();
    expect(h.voice.sent.last, 'cancel', reason: 'left of the zone is the event block, not the mic');
  });

  testWidgets('VI/EN switch: only with English on offer, under the mic, its whole zone switches', (tester) async {
    final h = await StripHarness.pump(tester, at: at(9, 20));
    expect(find.byKey(const Key('lang')), findsNothing, reason: 'the service offers no English');
    h.voice.emit(const VoiceReady('m', langs: ['vi', 'en']));
    await h.settle();
    expect(tester.getRect(find.byKey(const Key('lang'))), const Rect.fromLTWH(1360, 100, 120, 100));
    expect(tester.getRect(find.byKey(const Key('lang-chip'))), const Rect.fromLTWH(1392, 114, 64, 40),
        reason: 'drawn under the mic circle');
    expect(find.text('VI'), findsOneWidget);
    // Taps land left of the aim on this panel: the zone's far left corner still switches, and starts no listen.
    await tester.tapAt(const Offset(1362, 196));
    await h.settle();
    expect(find.text('EN'), findsOneWidget);
    expect(find.text('LỆNH TIẾNG ANH'), findsOneWidget);
    expect(h.voice.sent.where((m) => m.startsWith('listen')), isEmpty);
    await tester.tap(find.byKey(const Key('mic')));
    await h.settle();
    expect(find.text('ĐANG NGHE · TIẾNG ANH'), findsOneWidget);
    expect(h.voice.listenLangs, ['en']);
    h.voice.emit(const VoiceProcessing('l1'));
    h.voice.emit(const VoiceFinal('l1', 'Blah blah.'));
    await h.settle();
    expect(find.text('Thử: Set a timer for 25 minutes · Add a note: buy milk · Remind me to call Lan at 3 pm'), findsOneWidget);
  });

  testWidgets('recap: to-do rows stay clear of the mic touch zone', (tester) async {
    final h = await StripHarness.pump(tester, at: at(17, 40));
    await h.say('ghi lại đặt phòng họp thứ năm');
    await h.run(const Duration(minutes: 10));
    expect(find.text('CÒN 1 VIỆC · CHẠM ĐỂ ĐÁNH DẤU XONG'), findsOneWidget);
    final row = tester.getRect(find.byWidgetPredicate((w) => '${w.key}'.contains('recap-')));
    expect(row.right, lessThanOrEqualTo(stripWidth - micZoneWidth));
    await tester.tapAt(Offset(row.right - 2, row.center.dy));
    await h.settle();
    expect(find.text('CÒN 0 VIỆC · CHẠM ĐỂ ĐÁNH DẤU XONG'), findsOneWidget, reason: 'the far end of a row ticks it off');
    expect(h.voice.sent.where((m) => m.startsWith('listen')), hasLength(1), reason: 'only the dictation listened');
  });

  testWidgets('scenario 1: focus by voice, countdown, done alert, break', (tester) async {
    final h = await StripHarness.pump(tester, at: at(9, 20));
    await h.say('HẸN GIỜ HAI MƯƠI LĂM PHÚT ĐỂ TẬP TRUNG');
    expect(find.text('25:00'), findsOneWidget);
    expect(find.text('TẬP TRUNG'), findsOneWidget);
    expect(find.text('KHÔNG LÀM PHIỀN'), findsOneWidget);
    expect(find.text('Phiên 1 hôm nay'), findsOneWidget);
    await h.run(const Duration(minutes: 12));
    expect(find.text('13:00'), findsOneWidget);
    await h.say('tiếp theo là gì');
    expect(find.text('Họp thiết kế'), findsOneWidget, reason: 'answer card during focus');
    await h.run(const Duration(minutes: 13));
    expect(find.text('Xong 25 phút tập trung'), findsOneWidget);
    await tester.tap(find.byKey(const Key('alert-primary')));
    await h.settle();
    expect(find.text('NGHỈ 5 PHÚT'), findsOneWidget);
    expect(find.byKey(const Key('plain-timer')), findsOneWidget);
  });

  testWidgets('meeting soon is highlighted in the strip', (tester) async {
    final h = await StripHarness.pump(tester, at: at(10, 24, ), launchedAt: at(6));
    await h.run(const Duration(minutes: 1));
    expect(find.text('SẮP TỚI'), findsOneWidget);
    expect(find.text('Họp thiết kế'), findsWidgets);
    expect(h.voice.sent, contains('chime soft'));
  });

  testWidgets('scenario 2: note, reminder pin, reminder alert, done', (tester) async {
    final h = await StripHarness.pump(tester, at: at(14, 10));
    await h.say('ghi lại mua sữa và trứng trên đường về');
    expect(find.text('ĐÃ GHI NHANH'), findsOneWidget);
    expect(find.text('Mua sữa và trứng trên đường về'), findsOneWidget);
    await h.say('nhắc anh gọi cho chị Lan lúc ba giờ chiều');
    expect(find.text('ĐÃ HẸN NHẮC'), findsOneWidget);
    await h.run(const Duration(seconds: 7));
    expect(find.text('Gọi cho chị Lan'), findsOneWidget, reason: 'pin on the timeline');
    await h.run(const Duration(minutes: 50));
    expect(find.text('NHẮC VIỆC · 15:00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('alert-primary')));
    await h.settle();
    expect(find.text('NHẮC VIỆC · 15:00'), findsNothing);
    expect(h.c.reminders.single.done, isTrue);
  });

  testWidgets('recap: numbers and a tappable to-do list; swipe up for tomorrow and back', (tester) async {
    final h = await StripHarness.pump(tester, at: at(17, 40));
    await h.say('ghi lại gửi báo giá cho khách trước thứ sáu');
    await h.say('ghi lại đặt phòng họp thứ năm');
    await h.run(const Duration(minutes: 10));
    expect(find.text('TỔNG KẾT HÔM NAY'), findsOneWidget);
    expect(find.text('CÒN 2 VIỆC · CHẠM ĐỂ ĐÁNH DẤU XONG'), findsOneWidget);
    await tester.tap(find.text('Đặt phòng họp thứ năm'));
    await h.settle();
    expect(find.text('CÒN 1 VIỆC · CHẠM ĐỂ ĐÁNH DẤU XONG'), findsOneWidget);

    await tester.fling(find.text('TỔNG KẾT HÔM NAY'), const Offset(0, -150), 1200);
    await h.settle();
    expect(find.text('NGÀY MAI'), findsOneWidget);
    expect(find.text('Sync với team design'), findsWidgets);
    await tester.fling(find.text('Vuốt xuống để về hôm nay'), const Offset(0, 150), 1200);
    await h.settle();
    expect(h.c.screen, Screen.home);
    expect(find.text('Vuốt xuống để về hôm nay'), findsNothing);
    // After the last meeting (Review ends 17:45) the strip points at tomorrow.
    expect(find.text('NGÀY MAI'), findsOneWidget);
  });

  testWidgets('night: black, a tap shows the clock, it hides again', (tester) async {
    final h = await StripHarness.pump(tester, at: at(23, 10));
    expect(find.text('23:10'), findsNothing);
    expect(find.byKey(const Key('mic')), findsNothing);
    await tester.tapAt(const Offset(700, 160));
    await h.settle();
    expect(find.text('23:10'), findsOneWidget);
    expect(find.text('SÁNG MAI'), findsOneWidget);
    expect(find.text('08:30 · Sync với team design'), findsOneWidget);
    await h.run(const Duration(seconds: 10));
    expect(find.text('23:10'), findsNothing);
  });

  testWidgets('"tắt màn" in the day: dark; tap; "Bật màn" turns it back on', (tester) async {
    final h = await StripHarness.pump(tester, at: at(15));
    await h.say('tắt màn hình đi');
    expect(find.text('TIẾP THEO'), findsNothing);
    await tester.tapAt(const Offset(700, 160));
    await h.settle();
    await tester.tap(find.byKey(const Key('screen-on')));
    await h.settle();
    expect(h.c.night, isFalse);
    expect(find.text('15:00'), findsOneWidget);
  });

  testWidgets('not understood: shows what was heard and examples', (tester) async {
    final h = await StripHarness.pump(tester, at: at(10));
    await h.say('thời tiết hôm nay thế nào');
    expect(find.text('CHƯA HIỂU'), findsOneWidget);
    expect(find.text('“thời tiết hôm nay thế nào”'), findsOneWidget);
    expect(find.textContaining('Thử: '), findsOneWidget);
  });

  testWidgets('voice service down: the overlay says so', (tester) async {
    final h = await StripHarness.pump(tester, at: at(10));
    h.voice.isReady = false;
    await tester.tap(find.byKey(const Key('mic')));
    await h.settle();
    expect(find.text('GIỌNG NÓI CHƯA SẴN SÀNG'), findsOneWidget);
  });

  testWidgets('reminder without a time: pick "15 phút"', (tester) async {
    final h = await StripHarness.pump(tester, at: at(14));
    await h.say('nhắc anh mua quà sinh nhật mẹ');
    expect(find.text('NHẮC LÚC NÀO?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ask-15')));
    await h.settle();
    expect(h.c.reminders.single.at, at(14, 15));
    expect(find.text('ĐÃ HẸN NHẮC'), findsOneWidget);
  });

  testWidgets('long Vietnamese text is cut, not overflowing', (tester) async {
    final h = await StripHarness.pump(tester, at: at(11));
    const long = 'ghi lại chuẩn bị tài liệu thuyết trình quý bốn cho buổi họp hội đồng quản trị mở rộng vào cuối tuần sau';
    await h.say(long);
    expect(tester.takeException(), isNull);
    await h.say('nhắc anh chuẩn bị tài liệu thuyết trình quý bốn cho buổi họp hội đồng quản trị sau 1 phút');
    await h.run(const Duration(minutes: 1));
    expect(find.textContaining('NHẮC VIỆC'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clock not set yet: placeholder instead of a wrong time', (tester) async {
    await StripHarness.pump(tester, at: DateTime(1970, 1, 1, 0, 3));
    expect(find.text('--:--'), findsOneWidget);
    expect(find.text('ĐANG CHỜ GIỜ CHUẨN'), findsOneWidget);
  });

  testWidgets('the quick sample meeting is on the timeline', (tester) async {
    final h = await StripHarness.pump(tester, at: at(15, 10), launchedAt: at(15, 10));
    expect(find.text(SampleCalendarSource.quickTitle), findsWidgets);
    expect(h.c.screen, Screen.home);
  });
}
