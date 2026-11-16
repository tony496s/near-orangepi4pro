import '../core/clock.dart';
import '../domain/day_plan.dart';
import '../domain/models.dart';

class ScheduleSettings {
  const ScheduleSettings({
    this.meetingLead = const Duration(minutes: 5),
    this.recapAt = const Duration(hours: 17, minutes: 50),
    this.recapWindow = const Duration(hours: 2),
    this.nightStart = const Duration(hours: 23),
    this.nightEnd = const Duration(hours: 6, minutes: 30),
  });

  final Duration meetingLead;

  /// Time of day for the automatic recap, and how long after it a late start still shows it.
  final Duration recapAt;
  final Duration recapWindow;

  /// Night mode window (time of day); may wrap past midnight.
  final Duration nightStart;
  final Duration nightEnd;
}

/// Something the strip should react to now.
sealed class Signal {
  const Signal();
}

final class TimerFinished extends Signal {
  const TimerFinished(this.timer);
  final ActiveTimer timer;
}

final class ReminderDue extends Signal {
  const ReminderDue(this.reminder);
  final Reminder reminder;
}

final class MeetingSoon extends Signal {
  const MeetingSoon(this.event);
  final CalendarEvent event;
}

final class RecapTime extends Signal {
  const RecapTime();
}

Duration _timeOfDay(DateTime t) => Duration(hours: t.hour, minutes: t.minute, seconds: t.second);

/// Whether [now] falls in the night window.
bool isNightTime(DateTime now, ScheduleSettings s) {
  final t = _timeOfDay(now);
  return s.nightStart <= s.nightEnd ? (t >= s.nightStart && t < s.nightEnd) : (t >= s.nightStart || t < s.nightEnd);
}

/// The end of the night window that [now] is in (the next [ScheduleSettings.nightEnd] time of day).
DateTime nightEndsAt(DateTime now, ScheduleSettings s) {
  final today = dayOf(now).add(s.nightEnd);
  return today.isAfter(now) ? today : today.add(const Duration(days: 1));
}

/// Pure check of what is due at [now]. The caller remembers what it already handled ([announced] event ids,
/// [lastRecapDay], reminders' `firedAt`) so each signal is raised once. With an invalid clock nothing fires.
List<Signal> checkSchedule({
  required DateTime now,
  required ActiveTimer? timer,
  required List<Reminder> reminders,
  required DayPlan plan,
  required Set<String> announced,
  required String? lastRecapDay,
  required String todayKey,
  ScheduleSettings settings = const ScheduleSettings(),
}) {
  if (!clockLooksValid(now)) return const [];
  final out = <Signal>[];
  if (timer != null && timer.isDone(now)) out.add(TimerFinished(timer));
  for (final r in reminders) {
    if (r.isDue(now)) out.add(ReminderDue(r));
  }
  for (final e in plan.on(now)) {
    if (e.kind == EventKind.deadline || e.kind == EventKind.meal || announced.contains(e.id)) continue;
    if (!now.isBefore(e.start.subtract(settings.meetingLead)) && now.isBefore(e.start)) out.add(MeetingSoon(e));
  }
  final recap = dayOf(now).add(settings.recapAt);
  if (lastRecapDay != todayKey && !now.isBefore(recap) && now.isBefore(recap.add(settings.recapWindow))) {
    out.add(const RecapTime());
  }
  return out;
}
