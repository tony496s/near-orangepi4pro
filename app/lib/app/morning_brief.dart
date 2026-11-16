import '../core/clock.dart';
import '../data/local_store.dart' show dayKey;
import '../domain/day_plan.dart';
import '../domain/models.dart';

/// The morning brief shows by itself once a day, from 06:00 (once the night is over) until noon.
const briefFrom = Duration(hours: 6);
const briefUntil = Duration(hours: 12);

/// Shortest free stretch worth naming as "rảnh dài nhất".
const briefMinFree = Duration(minutes: 30);

/// Whether today's brief is still to show by itself at [now]: in the morning window and not shown yet today
/// ([lastBriefDay] is the [dayKey] of the day it last showed). Never with a clock that is not set yet. Whether the
/// strip is free to show it (awake, no alert, ...) is for the caller to say.
bool morningBriefDue(DateTime now, String? lastBriefDay) {
  if (!clockLooksValid(now) || lastBriefDay == dayKey(now)) return false;
  final day = dayOf(now);
  return !now.isBefore(day.add(briefFrom)) && now.isBefore(day.add(briefUntil));
}

/// A note or reminder still open from an earlier day.
class CarriedItem {
  const CarriedItem(this.id, this.text);
  final String id;
  final String text;
}

/// What the morning brief shows (scenario 6, 08:25 "Sáng hôm sau, việc còn tồn đã chờ sẵn").
class MorningBrief {
  const MorningBrief({required this.meetings, required this.longestFree, required this.firstMeeting, required this.carried});

  /// Meetings on today's calendar.
  final int meetings;

  /// The longest free stretch of today's working hours still ahead (at least [briefMinFree]); null: none.
  final FreeSlot? longestFree;

  /// The first meeting of today that has not ended, highlighted on the timeline.
  final CalendarEvent? firstMeeting;

  /// What the recap left open on earlier days: notes not done and made before today, reminders not done and due
  /// before today. Notes first, then reminders, as on the recap.
  final List<CarriedItem> carried;
}

MorningBrief morningBriefOf({
  required DateTime now,
  required DayPlan plan,
  required List<Note> notes,
  required List<Reminder> reminders,
}) {
  final today = dayOf(now);
  FreeSlot? longest;
  for (final s in plan.freeSlots(now, minLength: Duration.zero)) {
    if (!s.end.isAfter(now)) continue;
    final slot = s.start.isBefore(now) ? FreeSlot(now, s.end) : s;
    if (slot.length < briefMinFree) continue;
    if (longest == null || slot.length > longest.length) longest = slot;
  }
  return MorningBrief(
    meetings: plan.meetingCount(now),
    longestFree: longest,
    firstMeeting: plan.on(now).where((e) => e.kind == EventKind.meeting && e.end.isAfter(now)).firstOrNull,
    carried: [
      for (final n in notes)
        if (!n.done && n.createdAt.isBefore(today)) CarriedItem(n.id, n.text),
      for (final r in reminders)
        if (!r.done && r.at.isBefore(today)) CarriedItem(r.id, r.text),
    ],
  );
}
