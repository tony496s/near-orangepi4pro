import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/ui/theme.dart' show micZoneWidth, stripWidth;

import '../support/fonts.dart';
import '../support/strip.dart';

void main() {
  setUpAll(loadAppFonts);
  final day = DateTime(2026, 11, 16);
  DateTime at(int h, [int m = 0]) => day.add(Duration(hours: h, minutes: m));

  testWidgets('the question at 10:12: texts, buttons, both bars, one clash, ticks 10:10-10:40, clear of the mic',
      (tester) async {
    final h = await StripHarness.pump(tester, at: at(10, 12));
    await h.say('hẹn giờ 25 phút');
    expect(find.byKey(const Key('ask-fit-screen')), findsOneWidget);
    for (final t in [
      'HẸN GIỜ 25 PHÚT?',
      '10:30 có Họp thiết kế',
      'Từ giờ tới lúc họp chỉ còn 18 phút',
      'Hẹn 15 phút',
      'Vẫn 25 phút',
      '15 phút · xong 10:27, trước họp 3 phút',
      '25 phút · lấn 7 phút vào giờ họp',
      'HỌP THIẾT KẾ · 10:30',
      'BÂY GIỜ',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.byKey(const Key('ask-fit-bar-fit')), findsOneWidget);
    expect(find.byKey(const Key('ask-fit-bar-asked')), findsOneWidget);
    expect(find.byKey(const Key('ask-fit-clash')), findsOneWidget, reason: 'only the 25 min bar clashes');
    for (final t in ['10:10', '10:15', '10:20', '10:25', '10:30', '10:35', '10:40']) {
      expect(find.text(t), findsOneWidget, reason: 'tick $t');
    }
    expect(find.text('10:45'), findsNothing);
    expect(find.byKey(const Key('mic')), findsOneWidget, reason: 'the mic stays');

    // Everything above y 200 stays left of the mic and VI/EN zone; the bars fit in the strip.
    final zoneLeft = stripWidth - micZoneWidth;
    for (final k in ['ask-fit-fit', 'ask-fit-asked']) {
      final r = tester.getRect(find.byKey(Key(k)));
      expect(r.right, lessThanOrEqualTo(zoneLeft), reason: k);
      expect(r.height, greaterThanOrEqualTo(48), reason: k);
    }
    for (final t in ['HẸN GIỜ 25 PHÚT?', '10:30 có Họp thiết kế', 'Từ giờ tới lúc họp chỉ còn 18 phút']) {
      expect(tester.getRect(find.text(t)).right, lessThan(tester.getRect(find.byKey(const Key('ask-fit-fit'))).left), reason: t);
    }
    final fit = tester.getRect(find.byKey(const Key('ask-fit-bar-fit')));
    final asked = tester.getRect(find.byKey(const Key('ask-fit-bar-asked')));
    final clash = tester.getRect(find.byKey(const Key('ask-fit-clash')));
    expect(fit.top, greaterThanOrEqualTo(200));
    expect(fit.right, lessThan(clash.left), reason: 'the fitted bar ends before the meeting');
    expect(clash.right, closeTo(asked.right, .5), reason: 'hatched to the end of the 25 min bar');
    expect(asked.width / fit.width, closeTo(25 / 15, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('under 5 minutes fit: "Thôi" and "Vẫn", no overflow', (tester) async {
    final h = await StripHarness.pump(tester, at: at(10, 25));
    await h.say('hẹn giờ 25 phút');
    expect(find.text('Thôi'), findsOneWidget);
    expect(find.text('Vẫn 25 phút'), findsOneWidget);
    expect(find.byKey(const Key('ask-fit-fit')), findsNothing);
    expect(find.byKey(const Key('ask-fit-bar-fit')), findsNothing);
    expect(find.text('Từ giờ tới lúc họp chỉ còn 5 phút'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('ask-fit-cancel')));
    await h.settle();
    expect(find.byKey(const Key('ask-fit-screen')), findsNothing);
    expect(h.c.timer, isNull);
  });
}
