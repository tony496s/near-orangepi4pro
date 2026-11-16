import '../core/clock.dart';
import '../core/vi_format.dart';
import '../domain/calendar_diff.dart';
import '../domain/models.dart';
import 'app_controller.dart';

/// The meeting clock (scenario 6, 11:39): a meeting going on, how long is left, and what comes after.
class MeetingClock {
  const MeetingClock({required this.event, required this.left, required this.after});
  final CalendarEvent event;
  final Duration left;

  /// "Sau đó: 12:00 Ăn trưa · nghỉ 15 phút", or "Sau đó: hết lịch hôm nay".
  final String after;

  /// "ĐANG HỌP · 10:30 – 11:45"
  String get eyebrow => 'ĐANG HỌP · ${hhmm(event.start)} – ${hhmm(event.end)}';

  /// "06:00"
  String get countdown => mmss(left);

  /// "CÒN LẠI · HẾT GIỜ 11:45"
  String get sub => 'CÒN LẠI · HẾT GIỜ ${hhmm(event.end)}';
}

/// The meeting going on now (the latest started when they overlap), or null.
MeetingClock? meetingClockOf(AppController c) {
  final now = c.now;
  if (!c.clockValid) return null;
  final m = c.plan.events.where((e) => e.kind == EventKind.meeting && e.isOngoing(now)).lastOrNull;
  if (m == null) return null;
  final next = c.plan.events
      .where((e) => e.kind != EventKind.deadline && e.id != m.id && sameDay(e.start, now) && e.start.isAfter(now))
      .firstOrNull;
  final String after;
  if (next == null) {
    after = 'Sau đó: hết lịch hôm nay';
  } else {
    final gap = next.start.difference(m.end);
    final how = gap > Duration.zero
        ? 'nghỉ ${durationVi(gap)}'
        : gap == Duration.zero
            ? 'liền sau'
            : 'trùng ${durationVi(-gap)}';
    after = 'Sau đó: ${hhmm(next.start)} ${next.title} · $how';
  }
  return MeetingClock(event: m, left: m.end.difference(now), after: after);
}

/// Eyebrow, title and meta of the "lịch vừa đổi" flash for [moves] (the first one is shown, soonest first).
(String, String, String) movedTexts(List<EventMove> moves, DateTime now) {
  final m = moves.first;
  final a = m.after;
  final b = m.before;
  final sameDayMove = sameDay(a.start, b.start);
  final to = sameDayMove ? hhmm(a.start) : '${a.start.day}/${a.start.month} ${hhmm(a.start)}';
  final title = !sameDayMove
      ? '${a.title} dời sang ${shortDate(a.start)}'
      : m.shift.isNegative
          ? '${a.title} dời lên ${hhmm(a.start)}'
          : '${a.title} lùi sang ${hhmm(a.start)}';
  final who = a.organizer;
  final when = a.updatedAt;
  final meta = [
    if (sameDayMove) m.shift.isNegative ? 'Sớm hơn ${durationVi(-m.shift)}' : 'Muộn hơn ${durationVi(m.shift)}',
    if (sameDay(a.start, now) && a.start.isAfter(now)) 'còn ${durationVi(a.start.difference(now))}',
    if (a.isOngoing(now)) 'đang diễn ra',
    if (who != null || when != null)
      [?who, 'đổi', if (when != null && sameDay(when, now)) 'lúc ${hhmm(when)}'].join(' '),
    if (moves.length > 1) 'thêm ${moves.length - 1} lịch đổi',
  ].join(' · ');
  return ('LỊCH VỪA ĐỔI · ${hhmm(b.start)} → $to', title, meta);
}

/// "Lịch lưu lúc 15:02" (today), "Lịch lưu lúc 15:02 hôm qua", "Lịch lưu ngày 9/11", or "Chưa có lịch lưu".
String calendarSavedText(DateTime? fetchedAt, DateTime now) {
  if (fetchedAt == null) return 'Chưa có lịch lưu';
  if (sameDay(fetchedAt, now)) return 'Lịch lưu lúc ${hhmm(fetchedAt)}';
  if (sameDay(fetchedAt, now.subtract(const Duration(days: 1)))) return 'Lịch lưu lúc ${hhmm(fetchedAt)} hôm qua';
  return 'Lịch lưu ngày ${fetchedAt.day}/${fetchedAt.month}';
}
