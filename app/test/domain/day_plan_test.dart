import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/day_plan.dart';
import 'package:near_app/domain/models.dart';

import '../support/fakes.dart';

void main() {
  final d = DateTime(2026, 11, 16);
  final plan = DayPlan([
    ev('b', 'Họp thiết kế', d.add(const Duration(hours: 10, minutes: 30)), 75),
    ev('a', 'Họp đứng', d.add(const Duration(hours: 9)), 15),
    ev('l', 'Ăn trưa', d.add(const Duration(hours: 12)), 60, kind: EventKind.meal),
    ev('x', 'Hạn báo giá', d.add(const Duration(hours: 13)), 0, kind: EventKind.deadline),
    ev('t', 'Sync design', d.add(const Duration(days: 1, hours: 8, minutes: 30)), 60),
  ]);

  test('events are sorted and grouped by day', () {
    expect(plan.on(d).map((e) => e.id), ['a', 'b', 'l', 'x']);
    expect(plan.on(d.add(const Duration(days: 1))).map((e) => e.id), ['t']);
  });

  test('next skips past events and deadlines, and stays within today', () {
    expect(plan.next(d.add(const Duration(hours: 8, minutes: 52)))?.id, 'a');
    expect(plan.next(d.add(const Duration(hours: 9, minutes: 5)))?.id, 'b', reason: 'standup already started');
    expect(plan.next(d.add(const Duration(hours: 12, minutes: 30))), isNull, reason: 'only a deadline is left today');
  });

  test('current, remaining and counts', () {
    expect(plan.current(d.add(const Duration(hours: 9, minutes: 5)))?.id, 'a');
    expect(plan.current(d.add(const Duration(hours: 9, minutes: 30))), isNull);
    expect(plan.remainingToday(d.add(const Duration(hours: 11))).map((e) => e.id), ['b', 'l']);
    expect(plan.meetingCount(d), 2);
    expect(plan.firstTomorrow(d.add(const Duration(hours: 20)))?.id, 't');
  });

  test('event details', () {
    final t = DateTime(2026, 11, 16, 10);
    expect(CalendarEvent(id: 'z', title: 't', start: t, end: t, place: 'Phòng 3', people: 4).details, 'Phòng 3 · 4 người');
    expect(CalendarEvent(id: 'y', title: 't', start: t, end: t, people: 2).details, '2 người');
    expect(CalendarEvent(id: 'w', title: 't', start: t, end: t).details, '');
  });
}
