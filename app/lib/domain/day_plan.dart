import '../core/clock.dart';
import 'models.dart';

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
}
