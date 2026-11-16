import '../core/clock.dart';
import 'models.dart';

/// A free stretch of a working day.
class FreeSlot {
  const FreeSlot(this.start, this.end);
  final DateTime start;
  final DateTime end;
  Duration get length => end.difference(start);

  @override
  bool operator ==(Object other) => other is FreeSlot && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'FreeSlot($start – $end)';
}

/// Questions about the calendar: what is next, what is on a given day, how busy was today.
class DayPlan {
  DayPlan(Iterable<CalendarEvent> events) : events = List.unmodifiable(events.toList()..sort(_byStart));

  final List<CalendarEvent> events;

  static int _byStart(CalendarEvent a, CalendarEvent b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.end.compareTo(b.end);
  }

  /// Events starting on the calendar day of [day].
  List<CalendarEvent> on(DateTime day) => events.where((e) => sameDay(e.start, day)).toList();

  /// The first event of today that starts after [now]. Personal items count too; deadlines do not ("next" is about
  /// where to be).
  CalendarEvent? next(DateTime now) {
    for (final e in events) {
      if (e.kind != EventKind.deadline && sameDay(e.start, now) && e.start.isAfter(now)) return e;
    }
    return null;
  }

  /// The event going on at [now], if any (the latest-starting one when they overlap).
  CalendarEvent? current(DateTime now) {
    CalendarEvent? found;
    for (final e in events) {
      if (e.kind != EventKind.deadline && e.isOngoing(now)) found = e;
    }
    return found;
  }

  /// Today's events that have not ended yet.
  List<CalendarEvent> remainingToday(DateTime now) =>
      on(now).where((e) => e.kind != EventKind.deadline && e.end.isAfter(now)).toList();

  /// Number of meetings on the day of [day].
  int meetingCount(DateTime day) => on(day).where((e) => e.kind == EventKind.meeting).length;

  /// The first event of the day after [now] (for "ngày mai").
  CalendarEvent? firstTomorrow(DateTime now) {
    final list = on(dayOf(now).add(const Duration(days: 1))).where((e) => e.kind != EventKind.deadline);
    return list.isEmpty ? null : list.first;
  }

  /// The first event from [now]'s day on whose title contains [query] (case-insensitive), for "còn mấy ngày tới hạn …".
  CalendarEvent? findAhead(String query, DateTime now) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return null;
    final from = dayOf(now);
    for (final e in events) {
      if (!e.start.isBefore(from) && e.title.toLowerCase().contains(q)) return e;
    }
    return null;
  }

  /// Working hours used for free slots (the demo: Thursday free 09:15 – 13:00 and 14:30 – 18:00).
  static const workStart = Duration(hours: 9);
  static const workEnd = Duration(hours: 18);

  /// The Monday-to-Sunday week that holds [now], as 7 midnights.
  static List<DateTime> weekOf(DateTime now) {
    final d = dayOf(now);
    return [for (var i = 0; i < 7; i++) DateTime(d.year, d.month, d.day - (d.weekday - 1) + i)];
  }

  /// Free stretches of working hours on the day of [day], at least [minLength] long. Every event but a deadline
  /// takes time (a meal or a focus block is not free for a meeting).
  List<FreeSlot> freeSlots(DateTime day, {Duration minLength = const Duration(minutes: 30)}) {
    final d = dayOf(day);
    final open = d.add(workStart);
    final close = d.add(workEnd);
    final out = <FreeSlot>[];
    var cursor = open;
    for (final e in on(d)) {
      if (e.kind == EventKind.deadline || !e.end.isAfter(cursor) || !e.start.isBefore(close)) continue;
      if (e.start.isAfter(cursor)) out.add(FreeSlot(cursor, e.start));
      cursor = e.end;
      if (!cursor.isBefore(close)) break;
    }
    if (cursor.isBefore(close)) out.add(FreeSlot(cursor, close));
    return out.where((s) => s.length >= minLength).toList();
  }

  /// Total free time in working hours on the day of [day], counting every gap (even short ones).
  Duration freeTime(DateTime day) =>
      freeSlots(day, minLength: Duration.zero).fold(Duration.zero, (sum, s) => sum + s.length);

  /// Time spent in meetings on the day of [day] (the month view's bars).
  Duration meetingHours(DateTime day) =>
      on(day).where((e) => e.kind == EventKind.meeting).fold(Duration.zero, (sum, e) => sum + e.length);

  /// Deadlines starting in [from, to) (the week header's "hạn chót", the month view's marks).
  List<CalendarEvent> deadlines(DateTime from, DateTime to) =>
      events.where((e) => e.kind == EventKind.deadline && !e.start.isBefore(from) && e.start.isBefore(to)).toList();
}
