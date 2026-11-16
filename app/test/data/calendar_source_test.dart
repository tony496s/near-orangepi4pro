import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/data/calendar_source.dart';

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
}
