import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/scheduler.dart';
import 'package:near_app/domain/day_plan.dart';
import 'package:near_app/domain/models.dart';

import '../support/fakes.dart';

void main() {
  final d = DateTime(2026, 11, 16);
  final plan = DayPlan([
    ev('m', 'Họp thiết kế', d.add(const Duration(hours: 10, minutes: 30)), 75),
    ev('l', 'Ăn trưa', d.add(const Duration(hours: 12)), 60, kind: EventKind.meal),
  ]);

  List<Signal> at(DateTime now, {ActiveTimer? timer, List<Reminder> reminders = const [], Set<String> announced = const {}, String? recap}) =>
      checkSchedule(now: now, timer: timer, reminders: reminders, plan: plan, announced: announced, lastRecapDay: recap, todayKey: '2026-11-16');

  test('timer finishes exactly at its end', () {
    final tm = ActiveTimer(startedAt: d.add(const Duration(hours: 9, minutes: 20)), duration: const Duration(minutes: 25), focus: true);
    expect(at(d.add(const Duration(hours: 9, minutes: 44, seconds: 59)), timer: tm), isEmpty);
    expect(at(d.add(const Duration(hours: 9, minutes: 45)), timer: tm).single, isA<TimerFinished>());
  });

  test('reminder is due once its time comes and until it is fired', () {
    final r = Reminder(id: 'r', text: 'Gọi chị Lan', at: d.add(const Duration(hours: 15)), createdAt: d);
    expect(at(d.add(const Duration(hours: 14, minutes: 59)), reminders: [r]), isEmpty);
    expect(at(d.add(const Duration(hours: 15)), reminders: [r]).single, isA<ReminderDue>());
    final fired = r.copyWith(firedAt: () => d.add(const Duration(hours: 15)));
    expect(at(d.add(const Duration(hours: 15, minutes: 1)), reminders: [fired]), isEmpty);
    expect(at(d.add(const Duration(hours: 16)), reminders: [r.copyWith(doneAt: () => d)]), isEmpty);
  });

  test('meeting soon in the 5 minutes before it, once, and not for lunch', () {
    expect(at(d.add(const Duration(hours: 10, minutes: 24, seconds: 59))), isEmpty);
    expect((at(d.add(const Duration(hours: 10, minutes: 25))).single as MeetingSoon).event.id, 'm');
    expect(at(d.add(const Duration(hours: 10, minutes: 26)), announced: {'m'}), isEmpty);
    expect(at(d.add(const Duration(hours: 10, minutes: 30))), isEmpty, reason: 'already started');
    expect(at(d.add(const Duration(hours: 11, minutes: 57))), isEmpty, reason: 'meals are not announced');
  });

  test('recap at 17:50, once a day, not when starting much later', () {
    expect(at(d.add(const Duration(hours: 17, minutes: 49))), isEmpty);
    expect(at(d.add(const Duration(hours: 17, minutes: 50))).single, isA<RecapTime>());
    expect(at(d.add(const Duration(hours: 18)), recap: '2026-11-16'), isEmpty);
    expect(at(d.add(const Duration(hours: 20))), isEmpty, reason: 'outside the 2-hour window');
  });

  test('nothing fires while the clock is not set yet', () {
    final r = Reminder(id: 'r', text: 'x', at: DateTime(1970), createdAt: DateTime(1970));
    expect(checkSchedule(now: DateTime(1970, 1, 1, 18), timer: null, reminders: [r], plan: plan, announced: const {}, lastRecapDay: null, todayKey: '1970-01-01'), isEmpty);
  });

  test('night window wraps past midnight', () {
    const s = ScheduleSettings();
    expect(isNightTime(d.add(const Duration(hours: 22, minutes: 59)), s), isFalse);
    expect(isNightTime(d.add(const Duration(hours: 23)), s), isTrue);
    expect(isNightTime(d.add(const Duration(hours: 3)), s), isTrue);
    expect(isNightTime(d.add(const Duration(hours: 6, minutes: 30)), s), isFalse);
    expect(nightEndsAt(d.add(const Duration(hours: 23, minutes: 10)), s), DateTime(2026, 11, 17, 6, 30));
    expect(nightEndsAt(d.add(const Duration(hours: 2)), s), DateTime(2026, 11, 16, 6, 30));
  });
}
