import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/clock.dart';
import '../../core/vi_format.dart';
import '../../domain/day_plan.dart';
import '../../domain/models.dart';
import '../theme.dart';
import '../widgets/sky.dart';
import '../widgets/timeline.dart';

const _shortWeekdays = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];

/// "T5 19"
String weekdayShort(DateTime d) => '${_shortWeekdays[d.weekday - 1]} ${d.day}';

/// "16–22/11", or "30/11–6/12" across a month end.
String weekRange(List<DateTime> week) {
  final a = week.first;
  final b = week.last;
  return a.month == b.month ? '${a.day}–${b.day}/${b.month}' : '${a.day}/${a.month}–${b.day}/${b.month}';
}

/// Short duration for a free row: "3h45", "45ph", "2h".
String shortDuration(Duration d) {
  final m = d.inMinutes;
  if (m < 60) return '${m}ph';
  return m % 60 == 0 ? '${m ~/ 60}h' : '${m ~/ 60}h${two(m % 60)}';
}

/// One line of a day column: an event or a free stretch.
class WeekRow {
  const WeekRow.event(CalendarEvent this.event) : free = null;
  const WeekRow.free(FreeSlot this.free) : event = null;
  final CalendarEvent? event;
  final FreeSlot? free;

  DateTime get start => event?.start ?? free!.start;
}

/// The rows of one day column: its events, plus its free stretches when [withFree] (the "rảnh lúc nào" day).
List<WeekRow> weekRows(DayPlan plan, DateTime day, {bool withFree = false}) => [
  for (final e in plan.on(day)) WeekRow.event(e),
  if (withFree)
    for (final s in plan.freeSlots(day)) WeekRow.free(s),
]..sort((a, b) => a.start.compareTo(b.start));

/// This week as seven day columns (scenario 4: "tuần này có gì", "thứ năm rảnh lúc nào"). Tapping a day opens it.
class WeekScreen extends StatelessWidget {
  const WeekScreen({super.key, required this.c, required this.onOpenDay});
  final AppController c;
  final void Function(DateTime day) onOpenDay;

  static const left = 44.0;
  static const top = 60.0;
  static const height = 242.0;
  static const gap = 10.0;

  /// The columns end at the mic zone (x 1360): 5 × 196 + 2 × 138 + 6 × 10 = 1316.
  static const weekdayWidth = 196.0;
  static const weekendWidth = 138.0;
  static const rowHeight = 28.0;
  static const maxRows = 7;

  /// Left edge of the column of [weekday] (DateTime.monday..sunday).
  static double columnX(int weekday) {
    var x = left;
    for (var w = DateTime.monday; w < weekday; w++) {
      x += (w >= DateTime.saturday ? weekendWidth : weekdayWidth) + gap;
    }
    return x;
  }

  static double columnWidth(int weekday) => weekday >= DateTime.saturday ? weekendWidth : weekdayWidth;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final week = DayPlan.weekOf(now);
    final end = week.last.add(const Duration(days: 1));
    final focus = c.freeSlotsDay;
    final meetings = week.fold(0, (n, d) => n + c.plan.meetingCount(d));
    final dues = c.plan.deadlines(week.first, end).length;
    final String title;
    final String meta;
    if (focus == null) {
      title = 'TUẦN NÀY · ${weekRange(week)}';
      meta = '$meetings cuộc họp · $dues hạn chót';
    } else {
      final slots = c.plan.freeSlots(focus);
      title = '${weekdayName(focus).toUpperCase()} ${focus.day}/${focus.month} RẢNH LÚC NÀO';
      meta = slots.isEmpty
          ? 'Kín lịch trong giờ làm'
          : '${slots.length} khoảng rảnh · tổng ${durationVi(slots.fold(Duration.zero, (s, x) => s + x.length))}';
    }
    return Sky(
      kind: focus == null ? SkyKind.at(now) : SkyKind.done,
      child: Stack(
        children: [
          Positioned(
            left: left,
            top: 22,
            width: 1316,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(title, style: eyebrow(color: focus == null ? Ink.hot : Ink.cool)),
                const SizedBox(width: 18),
                Expanded(
                  child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: metaStyle(16)),
                ),
              ],
            ),
          ),
          for (final d in week)
            Positioned(
              key: ValueKey('week-day-${d.weekday}'),
              left: columnX(d.weekday),
              top: top,
              width: columnWidth(d.weekday),
              height: height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onOpenDay(d),
                child: Opacity(
                  opacity: focus != null && !sameDay(d, focus) ? .3 : 1,
                  child: _DayCard(
                    day: d,
                    rows: weekRows(c.plan, d, withFree: focus != null && sameDay(d, focus)),
                    today: sameDay(d, now),
                    focus: focus != null && sameDay(d, focus),
                    past: d.isBefore(dayOf(now)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({required this.day, required this.rows, required this.today, required this.focus, required this.past});
  final DateTime day;
  final List<WeekRow> rows;
  final bool today;
  final bool focus;
  final bool past;

  @override
  Widget build(BuildContext context) {
    final border = focus
        ? Ink.cool
        : today
        ? Ink.hot
        : const Color(0x1AF2EEE6);
    final shown = rows.length > WeekScreen.maxRows ? rows.take(WeekScreen.maxRows - 1).toList() : rows;
    final more = rows.length - shown.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 6),
      decoration: BoxDecoration(
        color: today ? const Color(0x1FFFB36B) : const Color(0x0FF2EEE6),
        border: Border.all(color: border, width: focus || today ? 1.5 : 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            today ? '${weekdayShort(day)} · HÔM NAY' : weekdayShort(day),
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: ts(15, weight: FontWeight.w600, color: today ? Ink.hot : (past ? Ink.faint : Ink.dim), spacing: 1),
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty) Text('Trống', style: ts(15, color: Ink.faint)),
          for (final r in shown)
            SizedBox(
              height: WeekScreen.rowHeight,
              child: _Row(r, past: past),
            ),
          if (more > 0) Text('+$more nữa', style: ts(14, color: Ink.dim)),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.row, {required this.past});
  final WeekRow row;
  final bool past;

  @override
  Widget build(BuildContext context) {
    final e = row.event;
    final f = row.free;
    final due = e?.kind == EventKind.deadline;
    final color = f != null || due ? Ink.cool : (past ? Ink.dim : Ink.ink);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 46,
          child: Text(hhmm(row.start), style: ts(13, color: f != null ? Ink.cool : Ink.dim)),
        ),
        Expanded(
          child: Text(
            f != null ? 'Rảnh tới ${hhmm(f.end)}' : e!.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts(16, weight: due || f != null ? FontWeight.w600 : FontWeight.w400, color: color),
          ),
        ),
        if (f != null) ...[const SizedBox(width: 4), Text(shortDuration(f.length), style: ts(12, color: Ink.cool))],
      ],
    );
  }
}

/// One day opened from the week view: its meetings, free time and the longest free stretch, over the day's timeline.
class DayScreen extends StatelessWidget {
  const DayScreen({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final day = dayOf(c.openDay ?? now);
    final events = c.plan.on(day);
    final slots = c.plan.freeSlots(day);
    FreeSlot? longest;
    for (final s in slots) {
      if (longest == null || s.length > longest.length) longest = s;
    }
    final meetings = c.plan.meetingCount(day);
    final isToday = sameDay(day, now);
    return Sky(
      kind: SkyKind.at(day.add(const Duration(hours: 9))),
      glowX: longest == null ? 740 : Timeline.x(longest.start).clamp(0, stripWidth),
      child: Stack(
        children: [
          Positioned(
            left: 44,
            top: 34,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isToday ? 'XEM NGÀY · HÔM NAY' : 'XEM NGÀY', style: eyebrow()),
                const SizedBox(height: 10),
                Text(shortDate(day), style: ts(60, weight: FontWeight.w600, height: 1.05)),
                const SizedBox(height: 10),
                Text('$meetings cuộc họp · rảnh ${durationVi(c.plan.freeTime(day))} trong giờ làm', style: metaStyle()),
              ],
            ),
          ),
          Positioned(
            right: micZoneWidth,
            top: 30,
            width: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  longest == null ? 'KÍN LỊCH TRONG GIỜ LÀM' : 'KHOẢNG RẢNH DÀI NHẤT',
                  style: eyebrow(color: Ink.cool),
                ),
                const SizedBox(height: 8),
                Text(
                  longest == null ? 'Không còn chỗ trống' : '${hhmm(longest.start)} – ${hhmm(longest.end)}',
                  textAlign: TextAlign.right,
                  style: ts(46, weight: FontWeight.w600, height: 1.12),
                ),
                const SizedBox(height: 10),
                if (longest != null) Text(durationVi(longest.length), style: metaStyle()),
              ],
            ),
          ),
          Positioned(
            left: 0,
            top: 212,
            child: Timeline(events: events, now: isToday ? now : null),
          ),
        ],
      ),
    );
  }
}
