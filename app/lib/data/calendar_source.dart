import '../core/clock.dart';
import '../core/vi_format.dart';
import '../domain/models.dart';

/// Where calendar events come from. The demo uses [SampleCalendarSource]; v1 adds a Google Calendar source.
abstract interface class CalendarSource {
  /// Events that start in [from, to).
  Future<List<CalendarEvent>> fetch(DateTime from, DateTime to);
}

/// (start, end, title, kind, place, people) of one sample event.
typedef SampleEventSpec = (String start, String end, String title, EventKind kind, String? place, int? people);

/// The sample week from near-demo.html, placed on the real dates so the strip always looks plausible.
///
/// The launch day gets [today] and the day after gets [tomorrow] (Monday and Tuesday of the demo week). Every other day
/// gets the demo week's events for its weekday ([week]). The deadline [deadlineTitle] falls on the first Friday after
/// launch, and [monthMarks] come back every month. One extra short meeting starts about 7 minutes after launch, so
/// "meeting in 5 minutes" can be shown at any time of day.
///
/// With a [clock], the launch day's 1:1 (14:30) moves 30 minutes earlier, organised by [movedBy], at [moveAt]:
/// [moveAfter] after launch (20 minutes by default), or when [moveNow] is called (the demo trigger). It only moves
/// while 14:00 is still ahead, so the change can be seen live ("Lịch đổi thì dải ngày đổi theo"). Without a clock the
/// sample day never changes.
class SampleCalendarSource implements CalendarSource {
  SampleCalendarSource({required this.launchedAt, this.clock, this.moveAfter = defaultMoveAfter});

  final DateTime launchedAt;
  final Clock? clock;

  /// How long after launch the 1:1 moves by itself; null: only on [moveNow].
  final Duration? moveAfter;

  static const defaultMoveAfter = Duration(minutes: 20);

  /// Id of the event that moves (today's 1:1), how far, and who moved it.
  static const movingId = 't3';
  static const moveBy = Duration(minutes: -30);
  static const movedBy = 'Minh';

  DateTime? _forcedMoveAt;

  /// When the 1:1 moves (or moved); null: it does not.
  DateTime? get moveAt {
    if (clock == null) return null;
    final auto = moveAfter == null ? null : launchedAt.add(moveAfter!);
    final forced = _forcedMoveAt;
    if (forced == null) return auto;
    return auto == null || forced.isBefore(auto) ? forced : auto;
  }

  /// Moves the 1:1 now (unless it has moved already). The next fetch returns it at its new time.
  void moveNow() {
    final c = clock;
    if (c == null) return;
    final t = c.now();
    final at = moveAt;
    if (at != null && !t.isBefore(at)) return;
    _forcedMoveAt = t;
  }

  static const List<SampleEventSpec> today = [
    ('09:00', '09:15', 'Họp đứng', EventKind.meeting, 'Phòng 3', null),
    ('10:30', '11:45', 'Họp thiết kế', EventKind.meeting, 'Phòng 3', 4),
    ('12:00', '13:00', 'Ăn trưa', EventKind.meal, null, null),
    ('14:30', '15:00', '1:1', EventKind.meeting, null, 2),
    ('16:00', '17:00', 'Tập trung sâu', EventKind.focus, null, null),
    ('17:00', '17:45', 'Review', EventKind.meeting, 'Phòng 2', 5),
  ];

  static const List<SampleEventSpec> tomorrow = [
    ('08:30', '09:30', 'Sync với team design', EventKind.meeting, 'Phòng 2', 6),
    ('09:45', '10:00', 'Họp đứng', EventKind.meeting, 'Phòng 3', null),
    ('13:30', '15:00', 'Hội thảo', EventKind.meeting, 'Hội trường', null),
    ('16:00', '17:00', 'Tập trung sâu', EventKind.focus, null, null),
  ];

  static const _standup = ('09:00', '09:15', 'Họp đứng', EventKind.meeting, 'Phòng 3', null);

  /// The demo week (scenario 4), by weekday. Monday and Tuesday are [today] and [tomorrow].
  static const Map<int, List<SampleEventSpec>> week = {
    DateTime.monday: today,
    DateTime.tuesday: tomorrow,
    DateTime.wednesday: [
      _standup,
      ('11:00', '12:00', 'Demo khách hàng', EventKind.meeting, 'Phòng 1', 4),
      ('15:00', '16:00', 'Phỏng vấn', EventKind.meeting, 'Phòng 2', 3),
      ('16:30', '17:30', 'Họp nhóm', EventKind.meeting, 'Phòng 3', 6),
    ],
    DateTime.thursday: [_standup, ('13:00', '14:30', 'Kế hoạch quý', EventKind.meeting, 'Phòng 1', 8)],
    DateTime.friday: [_standup, ('16:00', '17:00', 'Retro', EventKind.meeting, 'Phòng 2', 6)],
    DateTime.saturday: [],
    DateTime.sunday: [('17:00', '19:00', 'Đá bóng', EventKind.personal, null, null)],
  };

  /// The one-off deadline of the demo ("còn mấy ngày tới hạn gửi báo giá"), at 10:00 on the first Friday after launch.
  static const deadlineTitle = 'Hạn gửi báo giá cho khách';

  /// A second deadline that sounds like the first ("báo cáo" / "báo giá", demo 6), at 17:00 on the first Thursday after
  /// launch: "xong việc gửi báo cáo cho khách" matches both halfway, so the strip asks which one.
  static const reportTitle = 'Hạn gửi báo cáo tuần';

  /// Dates to remember, every month (day of month → title), shown as dots on the month view.
  static const monthMarks = {25: 'Release 1.2', 28: 'Sinh nhật mẹ'};

  static const quickTitle = 'Họp nhanh với team';

  @override
  Future<List<CalendarEvent>> fetch(DateTime from, DateTime to) async {
    final day0 = dayOf(launchedAt);
    final day1 = DateTime(day0.year, day0.month, day0.day + 1);
    final deadline = DateTime(day0.year, day0.month, day0.day + (DateTime.friday - day0.weekday + 6) % 7 + 1, 10);
    final out = <CalendarEvent>[..._place(today, day0, 't'), ..._place(tomorrow, day1, 'm')];
    final i = out.indexWhere((e) => e.id == movingId);
    final one = out[i];
    final moved = CalendarEvent(
      id: one.id,
      title: one.title,
      start: one.start.add(moveBy),
      end: one.end.add(moveBy),
      kind: one.kind,
      place: one.place,
      people: one.people,
      organizer: movedBy,
      updatedAt: moveAt,
    );
    // The quick meeting keeps clear of both slots of the 1:1, so it stays put when the 1:1 moves.
    final quick = _quickMeeting([...out, if (clock != null) moved]);
    if (quick != null) out.add(quick);
    final at = moveAt;
    final now = clock?.now();
    out[i] = now != null && at != null && !now.isBefore(at) && at.isBefore(moved.start)
        ? moved
        : CalendarEvent(
            id: one.id,
            title: one.title,
            start: one.start,
            end: one.end,
            kind: one.kind,
            place: one.place,
            people: one.people,
            organizer: movedBy);
    // Every other day of the range, from the demo week by weekday.
    for (var d = dayOf(from); d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1)) {
      final id = '${d.year}${two(d.month)}${two(d.day)}';
      if (!sameDay(d, day0) && !sameDay(d, day1)) out.addAll(_place(week[d.weekday]!, d, 'w$id-'));
      final mark = monthMarks[d.day];
      if (mark != null) {
        out.add(
          CalendarEvent(
            id: 'k$id',
            title: mark,
            start: d.add(const Duration(hours: 9)),
            end: d.add(const Duration(hours: 9)),
            kind: EventKind.deadline,
          ),
        );
      }
    }
    out.add(CalendarEvent(id: 'due', title: deadlineTitle, start: deadline, end: deadline, kind: EventKind.deadline));
    final report = DateTime(day0.year, day0.month, day0.day + (DateTime.thursday - day0.weekday + 6) % 7 + 1, 17);
    out.add(CalendarEvent(id: 'due-report', title: reportTitle, start: report, end: report, kind: EventKind.deadline));
    return out.where((e) => !e.start.isBefore(from) && e.start.isBefore(to)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  static List<CalendarEvent> _place(List<SampleEventSpec> specs, DateTime day, String prefix) {
    DateTime at(String hm) {
      final p = hm.split(':');
      return DateTime(day.year, day.month, day.day, int.parse(p[0]), int.parse(p[1]));
    }

    return [
      for (final (i, s) in specs.indexed)
        CalendarEvent(
          id: '$prefix$i',
          title: s.$3,
          start: at(s.$1),
          end: at(s.$2),
          kind: s.$4,
          place: s.$5,
          people: s.$6,
        ),
    ];
  }

  /// A 15-minute meeting at the first free 5-minute slot at least 7 minutes after launch, within 07:00-21:00.
  CalendarEvent? _quickMeeting(List<CalendarEvent> taken) {
    var start = launchedAt.add(const Duration(minutes: 7));
    final extra = (5 - start.minute % 5) % 5;
    start = DateTime(start.year, start.month, start.day, start.hour, start.minute + extra);
    final day = dayOf(launchedAt);
    final earliest = day.add(const Duration(hours: 7));
    if (start.isBefore(earliest)) start = earliest;
    final latest = day.add(const Duration(hours: 20, minutes: 45));
    while (!start.isAfter(latest)) {
      final end = start.add(const Duration(minutes: 15));
      final clash = taken.any((e) => start.isBefore(e.end) && e.start.isBefore(end));
      if (!clash) {
        return CalendarEvent(id: 'q', title: quickTitle, start: start, end: end, place: 'Phòng 2', people: 3);
      }
      start = start.add(const Duration(minutes: 5));
    }
    return null;
  }
}
