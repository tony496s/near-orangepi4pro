import '../core/clock.dart';
import '../core/vi_format.dart';
import '../domain/models.dart';
import 'app_controller.dart';

/// What the right-hand block of the day strip says.
class StripBlock {
  const StripBlock(this.eyebrow, this.title, this.meta, {this.cool = false, this.pulse = false});
  final String eyebrow;
  final String title;
  final String meta;
  final bool cool;
  final bool pulse;
}

String _when(CalendarEvent e, DateTime now) =>
    [hhmm(e.start), 'còn ${durationVi(e.start.difference(now))}', if (e.details.isNotEmpty) e.details].join(' · ');

/// Flash first (it answers what the user just said), then a meeting about to start, the event going on, what is
/// next today, the first thing tomorrow.
StripBlock stripBlock(AppController c) {
  final now = c.now;
  final f = c.flash;
  if (f != null) return StripBlock(f.eyebrow, f.title, f.meta, cool: f.cool);
  final soon = c.plan.events.where((e) => e.id == c.soonEventId).firstOrNull;
  if (soon != null) {
    final meta = [hhmm(soon.start), 'sau ${durationVi(soon.start.difference(now))}', if (soon.details.isNotEmpty) soon.details];
    return StripBlock('SẮP TỚI', soon.title, meta.join(' · '), pulse: true);
  }
  final cur = c.plan.current(now);
  final next = c.plan.next(now);
  if (cur != null && (next == null || next.start.difference(now) > const Duration(minutes: 15))) {
    return StripBlock('ĐANG DIỄN RA', cur.title, 'tới ${hhmm(cur.end)} · còn ${durationVi(cur.end.difference(now))}');
  }
  if (next != null) return StripBlock('TIẾP THEO', next.title, _when(next, now));
  final first = c.plan.firstTomorrow(now);
  if (first != null) {
    return StripBlock('NGÀY MAI', first.title, [hhmm(first.start), if (first.details.isNotEmpty) first.details].join(' · '));
  }
  return const StripBlock('HÔM NAY', 'Lịch trống', 'Nói “hẹn giờ 10 phút để tập trung” để bắt đầu');
}

/// A reminder pin on the timeline.
class Pin {
  const Pin(this.at, this.label, {this.done = false});
  final DateTime at;
  final String label;
  final bool done;
}

String _short(String s, [int max = 18]) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

List<Pin> todayPins(AppController c) => [
      for (final r in c.reminders)
        if (sameDay(r.at, c.now)) Pin(r.at, _short(r.text), done: r.done),
    ];

/// Numbers and the to-do list for the end-of-day recap.
class Recap {
  const Recap({required this.meetings, required this.focusMinutes, required this.sessions, required this.notes, required this.items});
  final int meetings;
  final int focusMinutes;
  final int sessions;
  final int notes;

  /// Open items first, then the ones done today; at most four.
  final List<RecapItem> items;

  int get open => items.where((i) => !i.done).length;
}

class RecapItem {
  const RecapItem(this.id, this.text, {required this.done});
  final String id;
  final String text;
  final bool done;
}

Recap recapOf(AppController c) {
  final now = c.now;
  final done = c.sessionsToday;
  final open = <RecapItem>[
    for (final n in c.notes)
      if (!n.done) RecapItem(n.id, n.text, done: false),
    for (final r in c.reminders)
      if (!r.done && sameDay(r.at, now)) RecapItem(r.id, r.text, done: false),
  ];
  final closed = <RecapItem>[
    for (final n in c.notes)
      if (n.done && sameDay(n.doneAt!, now)) RecapItem(n.id, n.text, done: true),
    for (final r in c.reminders)
      if (r.done && sameDay(r.doneAt!, now)) RecapItem(r.id, r.text, done: true),
  ];
  return Recap(
    meetings: c.plan.meetingCount(now),
    focusMinutes: done.fold(0, (m, s) => m + s.length.inMinutes),
    sessions: done.length,
    notes: c.notes.where((n) => sameDay(n.createdAt, now)).length,
    items: [...open, ...closed].take(4).toList(),
  );
}

/// Text of the full-screen alert at the front of the queue.
class AlertText {
  const AlertText(this.eyebrow, this.title, this.meta, this.primary, this.secondary, {required this.done});
  final String eyebrow;
  final String title;
  final String meta;
  final String primary;
  final String secondary;

  /// Timer-done look (teal check) rather than reminder look (warm).
  final bool done;
}

AlertText alertText(AppController c, Alert a) {
  final now = c.now;
  switch (a) {
    case TimerDoneAlert(:final timer, :final sessionNumber):
      final next = c.plan.next(now);
      final after = next == null ? '' : 'Tiếp theo: ${next.title} lúc ${hhmm(next.start)}';
      if (timer.focus) {
        return AlertText('HẾT GIỜ', 'Xong ${durationVi(timer.duration)} tập trung',
            ['Phiên $sessionNumber hôm nay', if (after.isNotEmpty) after].join(' · '), 'Nghỉ 5 phút', 'Để sau',
            done: true);
      }
      return AlertText('HẾT GIỜ', 'Hết ${durationVi(timer.duration)}', after,
          c.layout.split ? '+10 phút' : 'Thêm 5 phút', 'Xong', done: true);
    case GoldCrossedAlert(:final rule, :final price):
      return AlertText('VÀNG ${rule.above ? 'VƯỢT' : 'XUỐNG DƯỚI'} ${viPrice(rule.threshold)} ĐÔ', 'Giá bây giờ ${viNumber(price)}',
          'Đặt lúc ${hhmm(rule.setAt)} · số liệu mẫu', 'Xem chart', 'Tắt báo',
          done: false);
    case ReminderAlert(:final reminder):
      return AlertText('NHẮC VIỆC · ${hhmm(reminder.at)}', reminder.text, 'Hẹn lúc ${hhmm(reminder.createdAt)} bằng giọng nói',
          'Xong', '10 phút nữa',
          done: false);
  }
}
