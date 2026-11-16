import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/core/vi_format.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/ui/theme.dart' show micZoneWidth, stripWidth;
import 'package:near_app/ui/widgets/gold_mini.dart';
import 'package:near_app/ui/widgets/line_chart.dart';
import 'package:near_app/ui/widgets/timeline.dart';

import '../support/fonts.dart';
import '../support/strip.dart';

void main() {
  setUpAll(loadAppFonts);
  final day = DateTime(2026, 11, 16);
  DateTime at(int h, [int m = 0]) => day.add(Duration(hours: h, minutes: m));

  final mini = find.byKey(const Key('gold-mini'));

  /// Opens the gold chart, then goes back to the day strip ("không xem nữa thì chart thu về một góc").
  Future<void> openAndClose(StripHarness h) async {
    h.c.run(const ShowGold());
    await h.settle();
    h.c.run(const GoHome());
    await h.settle();
  }

  Rect rectOf(WidgetTester tester, Finder f) => tester.getRect(f);

  /// The right-hand block: the AnimatedSwitcher nearest to its eyebrow (the whole box it may fill, 600 px wide).
  Rect blockRect(WidgetTester tester, String eyebrow) =>
      tester.getRect(find.ancestor(of: find.text(eyebrow), matching: find.byType(AnimatedSwitcher)).first);

  void expectClear(WidgetTester tester, Rect tile, Rect other, String what) {
    expect(tile.overlaps(other), isFalse, reason: 'tile $tile overlaps $what $other');
  }

  testWidgets('hidden on a fresh start: the day strip is as before', (tester) async {
    final h = await StripHarness.pump(tester, at: at(8, 14));
    expect(h.c.goldMini, isFalse);
    expect(mini, findsNothing);
    expect(find.byType(GoldMini), findsNothing);
    expect(find.text('VÀNG · USD/OUNCE'), findsNothing);
    expect(find.text('TIẾP THEO'), findsOneWidget);
  });

  testWidgets('shows on the day strip after the gold chart was opened, with price, change and a small chart', (
    tester,
  ) async {
    final h = await StripHarness.pump(tester, at: at(8, 14));
    await openAndClose(h);
    expect(h.c.goldMini, isTrue);
    expect(mini, findsOneWidget);
    final g = h.c.gold;
    expect(find.text('VÀNG · USD/OUNCE'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('gold-mini-price'))).data, viNumber(g.last));
    final pct = g.changePct;
    expect(
      tester.widget<Text>(find.byKey(const Key('gold-mini-change'))).data,
      '${pct < 0 ? '-' : '+'}${viNumber(pct.abs(), decimals: 2)}%',
    );
    final chart = find.descendant(of: mini, matching: find.byType(LineChart));
    expect(tester.widget<LineChart>(chart).points.length, g.points.length, reason: 'the whole day so far');
    final size = tester.getSize(chart);
    expect(size.width, closeTo(GoldMini.width, .01));
    expect(size.height, GoldMini.chartHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden again the next day', (tester) async {
    final h = await StripHarness.pump(tester, at: at(8, 14));
    await openAndClose(h);
    expect(mini, findsOneWidget);
    await h.run(const Duration(minutes: 2));
    expect(mini, findsOneWidget, reason: 'stays for the rest of the day');
    h.clock.advance(const Duration(days: 1));
    h.c.tick();
    await h.settle();
    expect(h.c.goldMini, isFalse);
    expect(mini, findsNothing);
  });

  testWidgets('shows while a price alert is armed, without the chart having been opened', (tester) async {
    final h = await StripHarness.pump(tester, at: at(8, 14));
    expect(mini, findsNothing);
    h.c.run(SetGoldAlert((h.c.gold.last + 50).roundToDouble()));
    await h.settle();
    expect(h.c.goldMini, isTrue);
    expect(mini, findsOneWidget);
    expect(find.text('ĐÃ ĐẶT BÁO GIÁ'), findsOneWidget, reason: 'the confirmation is still in the right-hand block');
    expectClear(tester, rectOf(tester, mini), blockRect(tester, 'ĐÃ ĐẶT BÁO GIÁ'), 'the confirmation');
  });

  testWidgets('rises in: transparent and lower at first, in place after the entrance', (tester) async {
    final h = await StripHarness.pump(tester, at: at(8, 14));
    h.c.run(SetGoldAlert((h.c.gold.last + 50).roundToDouble()));
    await tester.pump();
    Opacity opacity() => tester.widget<Opacity>(find.descendant(of: mini, matching: find.byType(Opacity)).first);
    expect(opacity().opacity, 0);
    final early = tester.getRect(find.text('VÀNG · USD/OUNCE'));
    await tester.pump(GoldMini.riseFor);
    await tester.pump();
    expect(opacity().opacity, 1);
    final done = tester.getRect(find.text('VÀNG · USD/OUNCE'));
    expect(early.top - done.top, closeTo(14, .5), reason: 'climbs 14 px');
  });

  testWidgets('stays clear of the clock, date, right-hand block, timeline and mic strip, without overflow', (
    tester,
  ) async {
    final h = await StripHarness.pump(tester, at: at(8, 14));
    await openAndClose(h);
    final tile = rectOf(tester, mini);
    expect(tile.left, greaterThanOrEqualTo(440));
    expectClear(tester, tile, rectOf(tester, find.text('08:14')), 'the clock');
    expectClear(tester, tile, rectOf(tester, find.text(dateLine(at(8, 14)))), 'the date');
    expectClear(tester, tile, blockRect(tester, 'TIẾP THEO'), 'the right-hand block');
    expectClear(tester, tile, rectOf(tester, find.byType(Timeline)), 'the timeline');
    expectClear(tester, tile, const Rect.fromLTWH(stripWidth - micZoneWidth, 0, micZoneWidth, 200), 'the mic strip');
    for (final e in find.descendant(of: mini, matching: find.byType(Text)).evaluate()) {
      final r = tester.getRect(find.byWidget(e.widget));
      expect(
        tile.contains(r.topLeft) && r.right <= tile.right + .01 && r.bottom <= tile.bottom + .01,
        isTrue,
        reason: '${(e.widget as Text).data} at $r is outside the tile $tile',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the widest date of the year still ends left of the tile', (tester) async {
    // CHỦ NHẬT · 29 THÁNG MƯỜI MỘT
    final h = await StripHarness.pump(tester, at: DateTime(2026, 11, 29, 8, 14));
    await openAndClose(h);
    final date = rectOf(tester, find.text(dateLine(DateTime(2026, 11, 29))));
    expect(date.right, lessThan(rectOf(tester, mini).left));
  });

  testWidgets('a plain timer takes the middle: the tile waits until it ends', (tester) async {
    final h = await StripHarness.pump(tester, at: at(8, 14));
    await openAndClose(h);
    h.c.run(const StartTimer(Duration(minutes: 10), focus: false));
    await h.settle();
    expect(find.byKey(const Key('plain-timer')), findsOneWidget);
    expect(mini, findsNothing);
    h.c.run(const CancelTimer());
    await h.settle();
    expect(find.byKey(const Key('plain-timer')), findsNothing);
    expect(mini, findsOneWidget);
  });
}
