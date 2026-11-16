/// A timer that would run into a meeting asks first (demo 6, "Hẹn giờ mà biết lịch").
library;

import '../core/vi_format.dart';
import 'day_plan.dart';
import 'models.dart';

/// A fitted timer ends at least this long before the meeting.
const fitBuffer = Duration(minutes: 2);

/// The first meeting that starts after [now] and before the end of a [length] timer started now. A meeting already
/// going on is not in the way; meals, focus blocks, personal items and deadlines are not meetings.
CalendarEvent? meetingInTheWay(DayPlan plan, DateTime now, Duration length) {
  final end = now.add(length);
  for (final e in plan.events) {
    if (!e.start.isBefore(end)) break; // sorted by start
    if (e.kind == EventKind.meeting && e.start.isAfter(now)) return e;
  }
  return null;
}

/// The longest timer, in whole 5 minutes, that ends at least [buffer] before a meeting [gap] away (the demo's
/// `fitTimer`: floor((gap - 2) / 5) * 5). Zero when not even 5 minutes fit.
Duration fitBefore(Duration gap, {Duration buffer = fitBuffer}) {
  final room = gap - buffer;
  if (room.isNegative) return Duration.zero;
  return Duration(minutes: room.inSeconds ~/ 300 * 5);
}

/// Whole minutes between two times as the clock shows them ("10:12" to "10:30" is 18).
int clockMinutes(DateTime from, DateTime to) => _minute(to).difference(_minute(from)).inMinutes;

DateTime _minute(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute);

/// "25 phút"; a length that is not whole minutes in seconds ("90 giây").
String timerLength(Duration d) => d.inSeconds % 60 == 0 ? durationVi(d) : '${d.inSeconds} giây';

/// The focus screen's line for a session fitted before [meeting]: "Hết giờ lúc 10:27, trước giờ họp 3 phút".
String fitLine(DateTime end, CalendarEvent meeting) =>
    'Hết giờ lúc ${hhmm(end)}, trước giờ họp ${clockMinutes(end, meeting.start)} phút';

/// The question: a [asked] timer (focus or not) said at [at] would run into [meeting]; [fit] is the longest that ends
/// before it (zero: none).
class AskFit {
  const AskFit({required this.asked, required this.focus, required this.meeting, required this.at, required this.fit});

  final Duration asked;
  final bool focus;
  final CalendarEvent meeting;
  final DateTime at;
  final Duration fit;

  /// Whether "Hẹn N phút" is offered (at least 5 minutes fit).
  bool get canFit => fit >= const Duration(minutes: 5);
}

/// The buttons of the question: the fitted length, the length asked for, or neither ("Thôi").
enum AskFitAnswer { fit, asked, cancel }
