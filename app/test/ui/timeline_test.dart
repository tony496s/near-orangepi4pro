import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/models.dart';
import 'package:near_app/ui/theme.dart';
import 'package:near_app/ui/widgets/timeline.dart';

import '../support/fakes.dart';
import '../support/fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  DateTime at(int h, [int m = 0]) => DateTime(2026, 11, 16, h, m);

  Future<void> pump(WidgetTester tester, List<CalendarEvent> events) async {
    tester.view.physicalSize = const Size(stripWidth, Timeline.height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(alignment: Alignment.topLeft, child: Timeline(events: events, now: at(14, 41))),
    ));
  }

  double boxLeft(DateTime t) => Timeline.x(t);

  testWidgets('a short title that fits stays inside its narrow box', (tester) async {
    await pump(tester, [ev('a', '1:1', at(14, 30), 30)]);
    final label = tester.getRect(find.text('1:1'));
    expect(label.left, greaterThanOrEqualTo(boxLeft(at(14, 30))));
    expect(label.right, lessThanOrEqualTo(boxLeft(at(15))));
  });

  testWidgets('a label after a short event stops before the next event', (tester) async {
    // The board showed "Họp nhanh với team" (15:00, 15 min) written over "Tập trung sâu" (16:00).
    await pump(tester, [
      ev('a', '1:1', at(14, 30), 30),
      ev('b', 'Họp nhanh với team', at(15), 15),
      ev('c', 'Tập trung sâu', at(16), 60, kind: EventKind.focus),
    ]);
    final label = tester.getRect(find.text('Họp nhanh với team'));
    expect(label.left, greaterThan(boxLeft(at(15, 15)) - 4), reason: 'after its box');
    expect(label.right, lessThan(boxLeft(at(16))), reason: 'clear of the next event');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no label when there is no room before the next event', (tester) async {
    await pump(tester, [
      ev('a', 'Gọi khách hàng', at(10), 15),
      ev('b', 'Họp thiết kế', at(10, 20), 60),
    ]);
    expect(find.text('Gọi khách hàng'), findsNothing);
    expect(find.text('Họp thiết kế'), findsOneWidget);
  });

  testWidgets('the last event of the day can use the space up to the edge', (tester) async {
    await pump(tester, [ev('a', 'Gọi về nhà', at(19), 15)]);
    final label = tester.getRect(find.text('Gọi về nhà'));
    expect(label.left, greaterThan(boxLeft(at(19, 15)) - 4));
    expect(label.right, lessThanOrEqualTo(stripWidth));
  });

  testWidgets('events given out of order are laid out by start time', (tester) async {
    await pump(tester, [
      ev('c', 'Tập trung sâu', at(16), 60, kind: EventKind.focus),
      ev('b', 'Họp nhanh với team', at(15), 15),
    ]);
    expect(tester.getRect(find.text('Họp nhanh với team')).right, lessThan(boxLeft(at(16))));
  });

  testWidgets('deadlines have no box and do not block the label before them', (tester) async {
    await pump(tester, [
      ev('a', 'Gọi khách', at(11), 15),
      ev('d', 'Nộp báo giá', at(11, 20), 0, kind: EventKind.deadline),
      ev('b', 'Ăn trưa', at(12), 60, kind: EventKind.meal),
    ]);
    expect(find.text('Nộp báo giá'), findsNothing);
    expect(find.text('Gọi khách'), findsOneWidget);
  });
}
