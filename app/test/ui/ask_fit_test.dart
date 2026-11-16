import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/ui/screens/ask_fit.dart';
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
    expect(clash.right, closeTo(asked.right, .5), reason: 'tinted to the end of the 25 min bar');
    expect(asked.width / fit.width, closeTo(25 / 15, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the clash is a plain tint under the asked bar, so its label reads on top (no stripes)', (tester) async {
    final h = await StripHarness.pump(tester, at: at(10, 25));
    await h.say('hẹn giờ 25 phút');
    final clash = find.byKey(const Key('ask-fit-clash'));
    expect(
      find.descendant(of: clash, matching: find.byType(CustomPaint)),
      findsNothing,
      reason: 'no hatching',
    );
    final box = tester.widget<DecoratedBox>(find.descendant(of: clash, matching: find.byType(DecoratedBox)));
    expect((box.decoration as BoxDecoration).color, FitZoom.clashFill);
    // Painted before (under) the asked bar, whose label runs into the clash at 10:25.
    final stack = tester.widget<Stack>(find.descendant(of: find.byType(FitZoom), matching: find.byType(Stack)).first);
    int indexOf(String key) => stack.children.indexWhere((w) => w.key == Key(key));
    expect(indexOf('ask-fit-clash'), isNonNegative);
    expect(indexOf('ask-fit-clash'), lessThan(indexOf('ask-fit-bar-asked')));
    final label = tester.getRect(find.text('25 phút · lấn 20 phút vào giờ họp'));
    expect(label.right, greaterThan(tester.getRect(clash).left), reason: 'the label does reach the clash here');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the first and last tick labels sit whole inside the zoom', (tester) async {
    // 18:20 with a meeting at 18:25 on the board: the window starts at 18:15 and its label was cut to ":15".
    for (final (h0, m0, firstTick) in [(10, 12, '10:10'), (10, 25, '10:20')]) {
      final h = await StripHarness.pump(tester, at: at(h0, m0));
      await h.say('hẹn giờ 25 phút');
      final zoom = tester.getRect(find.byType(FitZoom));
      final ticks = find.descendant(
        of: find.byType(FitZoom),
        matching: find.byWidgetPredicate((w) => w is Text && RegExp(r'^\d\d:\d\d$').hasMatch(w.data ?? '')),
      );
      expect(ticks, findsAtLeastNWidgets(7));
      for (final e in ticks.evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        final t = (e.widget as Text).data;
        expect(r.left, greaterThanOrEqualTo(zoom.left - .5), reason: '$t at $h0:$m0');
        expect(r.right, lessThanOrEqualTo(zoom.right + .5), reason: '$t at $h0:$m0');
      }
      final first = tester.getRect(find.text(firstTick));
      expect(first.left, closeTo(zoom.left, .5), reason: 'the first label starts at the window edge');
    }
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
