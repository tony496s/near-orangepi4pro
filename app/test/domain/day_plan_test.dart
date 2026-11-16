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
    expect(
      CalendarEvent(id: 'z', title: 't', start: t, end: t, place: 'Phòng 3', people: 4).details,
      'Phòng 3 · 4 người',
    );
    expect(CalendarEvent(id: 'y', title: 't', start: t, end: t, people: 2).details, '2 người');
    expect(CalendarEvent(id: 'w', title: 't', start: t, end: t).details, '');
  });

  group('week, free slots and meeting hours (scenario 4)', () {
    final thu = DateTime(2026, 11, 19);
    final week = DayPlan([
      ev('s', 'Họp đứng', thu.add(const Duration(hours: 9)), 15),
      ev('q', 'Kế hoạch quý', thu.add(const Duration(hours: 13)), 90),
      ev('due', 'Hạn gửi báo giá', thu.add(const Duration(hours: 10)), 0, kind: EventKind.deadline),
    ]);

    test('weekOf gives Monday to Sunday, across a month end too', () {
      expect(DayPlan.weekOf(DateTime(2026, 11, 19, 15, 30)), [for (var i = 16; i <= 22; i++) DateTime(2026, 11, i)]);
      expect(DayPlan.weekOf(DateTime(2026, 11, 16)).first, DateTime(2026, 11, 16), reason: 'a Monday is its own start');
      expect(DayPlan.weekOf(DateTime(2026, 11, 22, 23)).first, DateTime(2026, 11, 16), reason: 'Sunday ends the week');
      final edge = DayPlan.weekOf(DateTime(2026, 12, 2));
      expect(edge.first, DateTime(2026, 11, 30));
      expect(edge.last, DateTime(2026, 12, 6));
    });

    test('Thursday of the demo is free 09:15 – 13:00 and 14:30 – 18:00; a deadline takes no time', () {
      expect(week.freeSlots(thu.add(const Duration(hours: 15))), [
        FreeSlot(thu.add(const Duration(hours: 9, minutes: 15)), thu.add(const Duration(hours: 13))),
        FreeSlot(thu.add(const Duration(hours: 14, minutes: 30)), thu.add(const Duration(hours: 18))),
      ]);
      expect(week.freeTime(thu), const Duration(hours: 7, minutes: 15));
    });

    test('an empty day is free all working day; a short gap is dropped unless asked for', () {
      final fri = thu.add(const Duration(days: 1));
      expect(week.freeSlots(fri), [FreeSlot(fri.add(DayPlan.workStart), fri.add(DayPlan.workEnd))]);
      final tight = DayPlan([
        ev('a', 'A', thu.add(const Duration(hours: 9)), 60),
        ev('b', 'B', thu.add(const Duration(hours: 10, minutes: 20)), 460), // to 18:00
      ]);
      expect(tight.freeSlots(thu), isEmpty, reason: '20 minutes is less than 30');
      expect(tight.freeSlots(thu, minLength: Duration.zero).single.length, const Duration(minutes: 20));
    });

    test('events before, after and overlapping working hours are clipped', () {
      final plan = DayPlan([
        ev('early', 'Sync', thu.add(const Duration(hours: 8, minutes: 30)), 60), // until 09:30
        ev('long', 'Hội thảo', thu.add(const Duration(hours: 11)), 120),
        ev('inner', 'Nhỏ', thu.add(const Duration(hours: 11, minutes: 30)), 30), // inside "long"
        ev('late', 'Tối', thu.add(const Duration(hours: 17, minutes: 30)), 120), // past 18:00
        ev('meal', 'Ăn', thu.add(const Duration(hours: 13)), 60, kind: EventKind.meal),
      ]);
      expect(plan.freeSlots(thu), [
        FreeSlot(thu.add(const Duration(hours: 9, minutes: 30)), thu.add(const Duration(hours: 11))),
        FreeSlot(thu.add(const Duration(hours: 14)), thu.add(const Duration(hours: 17, minutes: 30))),
      ]);
    });

    test('meeting hours count meetings only; deadlines list the range', () {
      expect(week.meetingHours(thu), const Duration(hours: 1, minutes: 45));
      expect(
        plan.meetingHours(d),
        const Duration(hours: 1, minutes: 30),
        reason: 'lunch and the deadline do not count',
      );
      expect(week.meetingHours(thu.add(const Duration(days: 1))), Duration.zero);
      expect(week.deadlines(DayPlan.weekOf(thu).first, thu.add(const Duration(days: 4))).single.id, 'due');
      expect(week.deadlines(thu.add(const Duration(days: 1)), thu.add(const Duration(days: 7))), isEmpty);
    });
  });
}
