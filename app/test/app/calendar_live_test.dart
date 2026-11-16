import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/app/live_presenter.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/domain/calendar_diff.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/models.dart';

import '../support/fakes.dart';

void main() {
  final day = DateTime(2026, 11, 16);
  DateTime at(int h, [int m = 0]) => day.add(Duration(hours: h, minutes: m));

  List<CalendarEvent> today() => [
        ev('design', 'Họp thiết kế', at(10, 30), 75),
        ev('lunch', 'Ăn trưa', at(12), 60, kind: EventKind.meal),
        ev('one', '1:1', at(14, 30), 30),
        ev('focus', 'Tập trung sâu', at(16), 60, kind: EventKind.focus),
      ];

  late FakeClock clock;
  late LiveCalendar cal;
  late AppController c;
  late List<String> logs;

  Future<void> make(DateTime t, {FakeProbe? probe}) async {
    clock = FakeClock(t);
    cal = LiveCalendar(today());
    logs = [];
    c = AppController(
        clock: clock, store: tempStore(), calendar: cal, voice: FakeVoice(), heardHold: Duration.zero, log: logs.add, network: probe);
    await c.start(ticker: false);
  }

  /// Ticks second by second, letting the async fetch and probe finish in between.
  Future<void> run(Duration d) async {
    for (var s = 0; s < d.inSeconds; s++) {
      clock.advance(const Duration(seconds: 1));
      c.tick();
      await pumpEventQueue(times: 2);
    }
  }

  CalendarEvent moved(String id, DateTime start, {String? by, DateTime? when}) {
    final e = today().singleWhere((e) => e.id == id);
    return CalendarEvent(
        id: id, title: e.title, start: start, end: start.add(e.length), kind: e.kind, place: e.place, organizer: by, updatedAt: when);
  }

  group('diff', () {
    test('moves are matched by id; new, cancelled, unchanged and deadlines are left out', () {
      final before = [...today(), ev('due', 'Hạn', at(17), 0, kind: EventKind.deadline)];
      final after = [
        for (final e in today())
          if (e.id != 'lunch') e.id == 'one' ? moved('one', at(14)) : e,
        ev('new', 'Mới', at(9), 15),
        ev('due', 'Hạn', at(18), 0, kind: EventKind.deadline),
      ];
      final m = movedEvents(before, after);
      expect(m.map((m) => (m.after.id, m.shift)), [('one', const Duration(minutes: -30))]);
    });
  });

  group('periodic fetch and the moved flash (scenario 6, 13:05)', () {
    test('fetched again every 5 minutes; a move flashes like the demo and leaves a ghost', () async {
      await make(at(13));
      expect(cal.fetches, 1);
      expect(c.flash, isNull, reason: 'the first fetch after start is not a change');
      cal.events = [for (final e in today()) e.id == 'one' ? moved('one', at(14), by: 'Minh', when: at(13, 4)) : e];
      await run(const Duration(minutes: 4, seconds: 59));
      expect(cal.fetches, 1);
      await run(const Duration(seconds: 1));
      expect(cal.fetches, 2);
      final f = c.flash!;
      expect((f.eyebrow, f.title, f.meta, f.cool),
          ('LỊCH VỪA ĐỔI · 14:30 → 14:00', '1:1 dời lên 14:00', 'Sớm hơn 30 phút · còn 55 phút · Minh đổi lúc 13:04', true));
      expect(f.until, at(13, 5).add(AppController.movedFlashFor));
      expect(c.plan.events.singleWhere((e) => e.id == 'one').start, at(14));
      final g = c.movedSlots.single;
      expect((g.eventId, g.start, g.end, g.until), ('one', at(14, 30), at(15), at(14, 30)));
      expect(logs.where((l) => l.contains('moved')), hasLength(1));
      await run(const Duration(minutes: 2));
      expect(c.flash, isNull, reason: 'the flash goes after two minutes');
      expect(c.movedSlots, hasLength(1), reason: 'the ghost stays');
    });

    test('later, without who: "lùi sang", no "đổi lúc"; the ghost lasts at most two hours', () async {
      await make(at(9));
      cal.events = [for (final e in today()) e.id == 'one' ? moved('one', at(15)) : e];
      await run(AppController.calendarEvery);
      expect((c.flash!.title, c.flash!.meta), ('1:1 lùi sang 15:00', 'Muộn hơn 30 phút · còn 5 giờ 55 phút'));
      expect(c.movedSlots.single.until, at(11, 5));
      clock.set(at(11, 5));
      expect(c.movedSlots, isEmpty);
    });

    test('moved during focus: a ghost but no flash; moved back: the ghost is the slot it just left; cancelled: gone',
        () async {
      await make(at(9));
      c.run(const StartTimer(Duration(minutes: 25), focus: true));
      cal.events = [for (final e in today()) e.id == 'one' ? moved('one', at(14)) : e];
      await run(AppController.calendarEvery);
      expect(c.flash, isNull);
      expect(c.movedSlots, hasLength(1));
      cal.events = today();
      await run(AppController.calendarEvery);
      expect(c.movedSlots.single.start, at(14), reason: 'the latest old slot');
      cal.events = [for (final e in today()) if (e.id != 'one') e];
      await run(AppController.calendarEvery);
      expect(c.movedSlots, isEmpty, reason: 'the event is gone');
    });

    test('a move of an event that is over, or on another day, is not announced', () async {
      await make(at(15, 30));
      cal.events = [for (final e in today()) e.id == 'design' ? moved('design', at(10)) : e];
      await run(AppController.calendarEvery);
      expect(c.flash, isNull);
      expect(c.movedSlots, isEmpty);
    });
  });

  group('offline', () {
    test('two failed probes in a row mean offline, logged once; back online fetches again', () async {
      final probe = FakeProbe();
      await make(at(15), probe: probe);
      await run(const Duration(seconds: 1));
      expect(probe.calls, 1);
      expect(c.offline, isFalse);
      probe.up = false;
      await run(AppController.probeEvery);
      expect(c.offline, isFalse, reason: 'one lost probe is not offline');
      await run(AppController.probeRetry);
      expect(c.offline, isTrue);
      await run(const Duration(minutes: 2));
      expect(logs.where((l) => l.startsWith('network')), ['network: offline'], reason: 'no log spam');
      expect(c.plan.events, isNotEmpty, reason: 'the last calendar stays');
      final fetches = cal.fetches;
      probe.up = true;
      await run(AppController.probeEvery);
      expect(c.offline, isFalse);
      expect(cal.fetches, fetches + 1, reason: 'fetched again when the network is back');
      expect(logs.last, 'network: back online');
    });

    test('a failing fetch counts as offline, keeps the plan, retries every minute and logs once', () async {
      await make(at(15, 2));
      expect(c.calendarFetchedAt, at(15, 2));
      cal.fail = true;
      await run(AppController.calendarEvery);
      expect(c.offline, isTrue);
      expect(c.plan.events, hasLength(4));
      expect(calendarSavedText(c.calendarFetchedAt, c.now), 'Lịch lưu lúc 15:02');
      await run(const Duration(minutes: 3));
      expect(cal.fetches, 5, reason: 'start, the failed one, then once a minute');
      expect(logs.where((l) => l.startsWith('calendar fetch failed')), hasLength(1));
      cal.fail = false;
      await run(AppController.calendarRetry);
      expect(c.offline, isFalse);
      expect(c.calendarFetchedAt, c.now);
    });

    test('calendarSavedText: today, yesterday, older, never', () {
      expect(calendarSavedText(at(15, 2), at(15, 20)), 'Lịch lưu lúc 15:02');
      expect(calendarSavedText(at(15, 2), at(15, 20).add(const Duration(days: 1))), 'Lịch lưu lúc 15:02 hôm qua');
      expect(calendarSavedText(at(15, 2), at(15, 20).add(const Duration(days: 5))), 'Lịch lưu ngày 16/11');
      expect(calendarSavedText(null, at(9)), 'Chưa có lịch lưu');
    });
  });

  group('meeting clock (scenario 6, 11:39)', () {
    test('the demo texts and the countdown', () async {
      await make(at(11, 39));
      final m = c.meeting!;
      expect((m.eyebrow, m.event.title, m.after, m.countdown, m.sub), (
        'ĐANG HỌP · 10:30 – 11:45',
        'Họp thiết kế',
        'Sau đó: 12:00 Ăn trưa · nghỉ 15 phút',
        '06:00',
        'CÒN LẠI · HẾT GIỜ 11:45'
      ));
      clock.advance(const Duration(seconds: 1));
      expect(c.meeting!.countdown, '05:59');
    });

    test('nothing after, right after, overlapping; not for a meal or focus block, not after the end', () async {
      await make(at(14, 40));
      expect(c.meeting!.after, 'Sau đó: 16:00 Tập trung sâu · nghỉ 1 giờ');
      cal.events = [ev('late', 'Họp muộn', at(18), 60)];
      await c.refreshCalendar();
      clock.set(at(18, 30));
      expect(c.meeting!.after, 'Sau đó: hết lịch hôm nay');
      cal.events = [ev('a', 'A', at(18), 60), ev('b', 'B', at(19), 15), ev('x', 'X', at(18, 50), 30)];
      await c.refreshCalendar();
      expect(c.meeting!.after, 'Sau đó: 18:50 X · trùng 10 phút');
      clock.set(at(18, 55));
      expect(c.meeting!.event.title, 'X', reason: 'the latest started');
      expect(c.meeting!.after, 'Sau đó: 19:00 B · trùng 20 phút');
      clock.set(at(12, 30));
      expect(c.meeting, isNull);
      await make(at(12, 30));
      expect(c.meeting, isNull, reason: 'lunch is not a meeting');
      clock.set(at(11, 45));
      expect(c.meeting, isNull, reason: 'over at its end');
    });
  });
}
