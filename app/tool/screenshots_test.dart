// Renders every screen of the strip to PNG for a visual check (real fonts, 1480x320).
// Not part of the test suite:  SHOT_DIR=/tmp/shots flutter test tool/screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/ui/strip_app.dart';

import '../test/support/fonts.dart';
import '../test/support/strip.dart';

void main() {
  setUpAll(loadAppFonts);
  final out = Directory(Platform.environment['SHOT_DIR'] ?? 'build/shots')..createSync(recursive: true);
  final day = DateTime(2026, 11, 16);
  DateTime at(int h, [int m = 0]) => day.add(Duration(hours: h, minutes: m));
  const k = Key('shot');

  Future<void> shot(WidgetTester tester, StripHarness h, String name) async {
    await tester.pumpWidget(RepaintBoundary(key: k, child: StripApp(controller: h.c)));
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      final b = tester.renderObject<RenderRepaintBoundary>(find.byKey(k));
      final img = await b.toImage();
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('${out.path}/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  testWidgets('screens', (tester) async {
    var h = await StripHarness.pump(tester, at: at(8, 52));
    await shot(tester, h, '01-ambient-morning');

    h = await StripHarness.pump(tester, at: at(9, 20));
    await h.say('hẹn giờ 25 phút để tập trung');
    await h.run(const Duration(minutes: 12));
    await shot(tester, h, '02-focus');
    await h.say('tiếp theo là gì');
    await shot(tester, h, '03-focus-card');
    await h.run(const Duration(minutes: 13));
    await shot(tester, h, '04-timer-done');

    h = await StripHarness.pump(tester, at: at(10, 25));
    await h.run(const Duration(seconds: 1));
    await shot(tester, h, '05-meeting-soon');

    h = await StripHarness.pump(tester, at: at(14, 10));
    await h.say('ghi lại mua sữa và trứng trên đường về');
    await shot(tester, h, '06-note-flash');
    await h.say('nhắc anh gọi cho chị Lan lúc ba giờ chiều');
    await h.say('hẹn giờ 10 phút');
    await h.run(const Duration(seconds: 7));
    await shot(tester, h, '07-pin-and-plain-timer');
    await h.run(const Duration(minutes: 50));
    await shot(tester, h, '08-reminder-alert');

    h = await StripHarness.pump(tester, at: at(17, 40));
    await h.say('ghi lại gửi báo giá cho khách trước thứ sáu');
    await h.say('ghi lại mua sữa và trứng trên đường về');
    await h.say('ghi lại đặt phòng họp thứ năm');
    h.c.toggleDone(h.c.notes.last.id);
    await h.run(const Duration(minutes: 10));
    await shot(tester, h, '09-recap');
    h.c.swipeUp();
    await shot(tester, h, '10-tomorrow');

    h = await StripHarness.pump(tester, at: at(23, 10));
    h.c.tapNight();
    await shot(tester, h, '11-night-peek');

    h = await StripHarness.pump(tester, at: at(10));
    h.c.talk();
    await shot(tester, h, '12-listening');
    await h.say('thời tiết hôm nay thế nào');
    await shot(tester, h, '13-not-understood');
    await h.say('nhắc anh mua quà sinh nhật mẹ');
    await shot(tester, h, '14-ask-time');
  });
}
