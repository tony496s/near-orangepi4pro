import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/domain/models.dart';

void main() {
  Future<List<String>> titles(DateTime launch) async {
    final day = DateTime(launch.year, launch.month, launch.day);
    final events = await SampleCalendarSource(launchedAt: launch).fetch(day, day.add(const Duration(days: 1)));
    return [for (final e in events) '${e.start.hour}:${e.start.minute.toString().padLeft(2, '0')} ${e.title}'];
  }

  test('sample day from the demo, on the launch date, with a quick meeting about 7 minutes after launch', () async {
    expect(await titles(DateTime(2026, 11, 16, 8, 30)), [
      '8:40 ${SampleCalendarSource.quickTitle}',
      '9:00 Họp đứng',
      '10:30 Họp thiết kế',
      '12:00 Ăn trưa',
      '14:30 1:1',
      '16:00 Làm sâu',
      '17:00 Review',
    ]);
  });

  test('the quick meeting moves to the next free slot instead of overlapping', () async {
    // 10:20 + 7 = 10:27 -> 10:30 clashes with the design review until 11:45.
    final list = await titles(DateTime(2026, 11, 16, 10, 20));
    expect(list, contains('11:45 ${SampleCalendarSource.quickTitle}'));
  });

  test('no quick meeting late in the evening', () async {
    final list = await titles(DateTime(2026, 11, 16, 21, 30));
    expect(list.where((s) => s.contains(SampleCalendarSource.quickTitle)), isEmpty);
  });

  test('tomorrow comes from the second sample day', () async {
    final launch = DateTime(2026, 11, 16, 8);
    final next = DateTime(2026, 11, 17);
    final events = await SampleCalendarSource(launchedAt: launch).fetch(next, next.add(const Duration(days: 1)));
    expect(events.first.title, 'Sync với team design');
    expect(events.first.start, DateTime(2026, 11, 17, 8, 30));
  });

  group('the demo week (scenario 4)', () {
    final launch = DateTime(2026, 11, 16, 8); // a Monday
    Future<List<CalendarEvent>> week() =>
        SampleCalendarSource(launchedAt: launch).fetch(DateTime(2026, 11, 16), DateTime(2026, 11, 23));
    List<String> on(List<CalendarEvent> list, int day) => [
      for (final e in list)
        if (e.start.day == day) '${e.start.hour}:${e.start.minute.toString().padLeft(2, '0')} ${e.title}',
    ];

    test('every weekday has its events; Saturday is empty, Sunday is football', () async {
      final list = await week();
      expect(on(list, 18), ['9:00 Họp đứng', '11:00 Demo khách hàng', '15:00 Phỏng vấn', '16:30 Họp nhóm']);
      expect(on(list, 19), ['9:00 Họp đứng', '13:00 Kế hoạch quý']);
      expect(on(list, 20), ['9:00 Họp đứng', '10:00 ${SampleCalendarSource.deadlineTitle}', '16:00 Retro']);
      expect(on(list, 21), isEmpty);
      expect(on(list, 22), ['17:00 Đá bóng']);
      expect(list.where((e) => e.start.day == 22).single.kind, EventKind.personal);
    });

    test('the launch day and the day after keep their own events, not the weekday table twice', () async {
      final list = await week();
      expect(on(list, 16).where((s) => s.endsWith('Họp đứng')), hasLength(1));
      expect(on(list, 17).first, '8:30 Sync với team design');
    });

    test('a launch on another weekday still gets today and tomorrow, and the rest by weekday', () async {
      final thu = DateTime(2026, 11, 19, 8);
      final list = await SampleCalendarSource(launchedAt: thu).fetch(DateTime(2026, 11, 16), DateTime(2026, 11, 23));
      expect(on(list, 19).where((s) => s.contains('Họp thiết kế')), hasLength(1), reason: 'launch day = sample today');
      expect(on(list, 20).first, '8:30 Sync với team design', reason: 'day after = sample tomorrow');
      expect(on(list, 16), [
        '9:00 Họp đứng',
        '10:30 Họp thiết kế',
        '12:00 Ăn trưa',
        '14:30 1:1',
        '16:00 Làm sâu',
        '17:00 Review',
      ], reason: 'a Monday before launch is the Monday table, without the quick meeting');
    });

    test('the deadline is at 10:00 on the first Friday after launch, zero length', () async {
      Future<CalendarEvent> due(DateTime launch) async {
        final from = DateTime(launch.year, launch.month, launch.day);
        final list = await SampleCalendarSource(launchedAt: launch).fetch(from, from.add(const Duration(days: 8)));
        return list.singleWhere((e) => e.title == SampleCalendarSource.deadlineTitle);
      }

      final mon = await due(DateTime(2026, 11, 16, 8));
      expect(mon.start, DateTime(2026, 11, 20, 10));
      expect(mon.length, Duration.zero);
      expect(mon.kind, EventKind.deadline);
      expect(
        (await due(DateTime(2026, 11, 20, 8))).start,
        DateTime(2026, 11, 27, 10),
        reason: 'a Friday launch: next week',
      );
      expect((await due(DateTime(2026, 11, 21, 8))).start, DateTime(2026, 11, 27, 10), reason: 'Saturday');
      expect(
        (await due(DateTime(2026, 11, 26, 8))).start,
        DateTime(2026, 11, 27, 10),
        reason: 'Thursday: the next day',
      );
    });

    test('monthly marks on the 25th and 28th, and none outside the range', () async {
      final list = await SampleCalendarSource(launchedAt: launch).fetch(DateTime(2026, 11, 1), DateTime(2026, 12, 1));
      final marks = list.where((e) => SampleCalendarSource.monthMarks.containsValue(e.title)).toList();
      expect([for (final m in marks) '${m.start.day} ${m.title}'], ['25 Release 1.2', '28 Sinh nhật mẹ']);
      expect(marks.every((m) => m.kind == EventKind.deadline), isTrue);
      expect((await week()).where((e) => SampleCalendarSource.monthMarks.containsValue(e.title)), isEmpty);
    });

    test('ids are unique across a whole month, and the range is respected', () async {
      final from = DateTime(2026, 11, 1);
      final to = DateTime(2026, 12, 1);
      final list = await SampleCalendarSource(launchedAt: launch).fetch(from, to);
      expect(list.map((e) => e.id).toSet(), hasLength(list.length));
      expect(list.every((e) => !e.start.isBefore(from) && e.start.isBefore(to)), isTrue);
      expect(list.first.start, DateTime(2026, 11, 1, 17), reason: '1/11 is a Sunday: football first');
    });
  });
}
