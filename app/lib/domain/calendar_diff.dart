import 'models.dart';

/// An event that is in two fetches of the calendar with a different start.
class EventMove {
  const EventMove(this.before, this.after);
  final CalendarEvent before;
  final CalendarEvent after;

  /// Negative: earlier.
  Duration get shift => after.start.difference(before.start);
}

/// Events (matched by id) whose start changed between [before] and [after], soonest new start first. New, cancelled
/// and deadline events are left out.
List<EventMove> movedEvents(Iterable<CalendarEvent> before, Iterable<CalendarEvent> after) {
  final old = {for (final e in before) e.id: e};
  final out = <EventMove>[
    for (final e in after)
      if (e.kind != EventKind.deadline && old[e.id] != null && old[e.id]!.start != e.start) EventMove(old[e.id]!, e),
  ]..sort((a, b) => a.after.start.compareTo(b.after.start));
  return out;
}

/// The old slot of a moved event, drawn as a dashed ghost on the timeline until [until].
class MovedSlot {
  const MovedSlot(this.eventId, this.start, this.end, {required this.until});
  final String eventId;
  final DateTime start;
  final DateTime end;
  final DateTime until;
}
