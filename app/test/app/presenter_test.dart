import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/app/presenter.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/models.dart';

import '../support/fakes.dart';

void main() {
  final day = DateTime(2026, 11, 16);
  final events = [
    ev('stand', 'Họp đứng', day.add(const Duration(hours: 9)), 15),
    ev('design', 'Họp thiết kế', day.add(const Duration(hours: 10, minutes: 30)), 75),
    ev('tmr', 'Sync với team design', day.add(const Duration(days: 1, hours: 8, minutes: 30)), 60),
  ];

  Future<AppController> at(int h, [int m = 0]) async {
    final c = AppController(
        clock: clockAt(h, m), store: tempStore(), calendar: FixedCalendar(events), voice: FakeVoice(), heardHold: Duration.zero, log: (_) {});
    await c.start(ticker: false);
    return c;
  }

  group('strip block', () {
    test('next event with time left and details', () async {
      final b = stripBlock(await at(8, 52));
      expect((b.eyebrow, b.title, b.meta), ('TIẾP THEO', 'Họp đứng', '09:00 · còn 8 phút · Phòng 3'));
    });

    test('an answer the user just asked for wins over the calendar', () async {
      final c = await at(8, 52);
      c.run(const AddNote('Mua sữa'));
      final b = stripBlock(c);
      expect((b.eyebrow, b.title, b.cool), ('ĐÃ GHI NHANH', 'Mua sữa', true));
    });

    test('meeting about to start pulses', () async {
      final c = await at(10, 25);
      final b = stripBlock(c);
      expect((b.eyebrow, b.pulse), ('SẮP TỚI', true));
      expect(b.meta, '10:30 · sau 5 phút · Phòng 3');
    });

    test('during a long meeting with nothing right after, show what is going on', () async {
      final b = stripBlock(await at(11));
      expect((b.eyebrow, b.title), ('ĐANG DIỄN RA', 'Họp thiết kế'));
      expect(b.meta, 'tới 11:45 · còn 45 phút');
    });

    test('after the last event, point at tomorrow', () async {
      final b = stripBlock(await at(18));
      expect((b.eyebrow, b.title, b.meta), ('NGÀY MAI', 'Sync với team design', '08:30 · Phòng 3'));
    });
  });

  test('pins are today\'s reminders, done ones marked', () async {
    final c = await at(14);
    c.run(AddReminder('Gọi chị Lan', day.add(const Duration(hours: 15))));
    c.run(AddReminder('Nộp báo giá', day.add(const Duration(days: 1, hours: 9))));
    expect(todayPins(c).map((p) => (p.label, p.done)), [('Gọi chị Lan', false)]);
  });

  test('recap counts and lists open items before done ones', () async {
    final c = await at(9, 20);
    c.run(const StartTimer(Duration(minutes: 25), focus: true));
    (c.clock as FakeClock).advance(const Duration(minutes: 25));
    c.tick();
    c.alertAction(AlertAction.secondary);
    c.run(const AddNote('Gửi báo giá'));
    c.run(const AddNote('Đặt phòng họp'));
    c.toggleDone(c.notes.last.id);
    final r = recapOf(c);
    expect((r.meetings, r.focusMinutes, r.sessions, r.notes), (2, 25, 1, 2));
    expect(r.items.map((i) => (i.text, i.done)), [('Gửi báo giá', false), ('Đặt phòng họp', true)]);
    expect(r.open, 1);
  });

  test('alert text for a focus session, a plain timer and a reminder', () async {
    final c = await at(9, 20);
    final focus = TimerDoneAlert(ActiveTimer(startedAt: c.now, duration: const Duration(minutes: 25), focus: true), 1, c.now);
    final a = alertText(c, focus);
    expect((a.title, a.primary, a.secondary, a.done), ('Xong 25 phút tập trung', 'Nghỉ 5 phút', 'Để sau', true));
    expect(a.meta, 'Phiên 1 hôm nay · Tiếp theo: Họp thiết kế lúc 10:30');
    final ten = TimerDoneAlert(ActiveTimer(startedAt: c.now, duration: const Duration(minutes: 10), focus: false), 0, c.now);
    expect((alertText(c, ten).title, alertText(c, ten).primary), ('Hết 10 phút', '+10 phút'),
        reason: 'on the columns (first start) the timer column offers ten more minutes');
    c.run(const SingleColumn());
    expect(alertText(c, ten).primary, 'Thêm 5 phút', reason: 'on the day strip');
    final r = Reminder(id: 'r', text: 'Gọi chị Lan', at: day.add(const Duration(hours: 15)), createdAt: day.add(const Duration(hours: 14, minutes: 12)));
    final ra = alertText(c, ReminderAlert(r, c.now));
    expect((ra.eyebrow, ra.title, ra.meta, ra.done), ('NHẮC VIỆC · 15:00', 'Gọi chị Lan', 'Hẹn lúc 14:12 bằng giọng nói', false));
  });
}
