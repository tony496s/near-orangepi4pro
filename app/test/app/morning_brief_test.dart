import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/morning_brief.dart';
import 'package:near_app/domain/day_plan.dart';
import 'package:near_app/domain/models.dart';

import '../support/fakes.dart';

void main() {
  final mon = DateTime(2026, 11, 16);
  final tue = DateTime(2026, 11, 17);
  DateTime t(int h, [int m = 0]) => tue.add(Duration(hours: h, minutes: m));

  // The demo's Tuesday: Sync 08:30-09:30, Họp đứng 09:45-10:00, Hội thảo 13:30-15:00, focus 16:00-17:00.
  final plan = DayPlan([
    ev('sync', 'Sync với team design', t(8, 30), 60),
    ev('stand', 'Họp đứng', t(9, 45), 15),
    ev('talk', 'Hội thảo', t(13, 30), 90),
    ev('deep', 'Tập trung sâu', t(16), 60, kind: EventKind.focus),
  ]);

  MorningBrief at(DateTime now, {List<Note> notes = const [], List<Reminder> reminders = const []}) =>
      morningBriefOf(now: now, plan: plan, notes: notes, reminders: reminders);

  group('due', () {
    test('from 06:00 until noon, once a day', () {
      expect(morningBriefDue(t(5, 59), null), isFalse);
      expect(morningBriefDue(t(6), null), isTrue);
      expect(morningBriefDue(t(11, 59), '2026-11-16'), isTrue, reason: 'shown yesterday');
      expect(morningBriefDue(t(8), '2026-11-17'), isFalse, reason: 'shown today');
      expect(morningBriefDue(t(12), null), isFalse, reason: 'the morning is over');
    });

    test('never while the clock is not set', () {
      expect(morningBriefDue(DateTime(1970, 1, 1, 8), null), isFalse);
    });
  });

  group('today', () {
    test('the demo at 08:25: three meetings, free 10:00-13:30, the Sync lit', () {
      final b = at(t(8, 25));
      expect(b.meetings, 3, reason: 'the focus block is not a meeting');
      expect(b.longestFree, FreeSlot(t(10), t(13, 30)));
      expect(b.firstMeeting!.id, 'sync');
    });

    test('later on: the free stretch starts now, the first meeting is the next one not over', () {
      final b = at(t(10, 20));
      expect(b.longestFree, FreeSlot(t(10, 20), t(13, 30)));
      expect(b.firstMeeting!.id, 'talk');
      final late = at(t(15, 10));
      expect(late.longestFree, FreeSlot(t(17), t(18)), reason: '15:10-16:00 is shorter');
      expect(late.firstMeeting, isNull);
      expect(at(t(17, 40)).longestFree, isNull, reason: 'under 30 minutes left');
    });
  });

  group('carried', () {
    test('notes and reminders from earlier days that are not done; not done ones, not today\'s', () {
      final b = at(t(8), notes: [
        Note(id: 'quote', text: 'Gửi báo giá', createdAt: mon.add(const Duration(hours: 14))),
        Note(id: 'room', text: 'Đặt phòng họp', createdAt: mon.add(const Duration(hours: 15)), doneAt: mon.add(const Duration(hours: 17))),
        Note(id: 'old', text: 'Gọi thợ sửa máy', createdAt: mon.subtract(const Duration(days: 3))),
        Note(id: 'new', text: 'Mua cà phê', createdAt: t(7, 30)),
      ], reminders: [
        Reminder(id: 'lan', text: 'Gọi chị Lan', at: mon.add(const Duration(hours: 15)), createdAt: mon, doneAt: mon.add(const Duration(hours: 15))),
        Reminder(id: 'gift', text: 'Mua quà', at: mon.add(const Duration(hours: 16)), createdAt: mon, firedAt: mon.add(const Duration(hours: 16))),
        Reminder(id: 'due', text: 'Nộp báo giá', at: t(9), createdAt: mon),
      ]);
      expect(b.carried.map((i) => i.id), ['quote', 'old', 'gift']);
      expect(b.carried.first.text, 'Gửi báo giá');
    });
  });
}
