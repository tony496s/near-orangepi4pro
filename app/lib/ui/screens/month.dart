import 'package:flutter/widgets.dart';

import '../../app/app_controller.dart';
import '../../core/clock.dart';
import '../../core/vi_format.dart';
import '../theme.dart';
import '../widgets/sky.dart';

/// Whole days from [from]'s day to [to]'s day (calendar days, not 24-hour blocks).
int daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// "Còn 4 ngày", "Ngày mai", "Hôm nay", "Đã qua 2 ngày".
String daysLeftVi(int days) {
  if (days == 0) return 'Hôm nay';
  if (days == 1) return 'Ngày mai';
  if (days < 0) return 'Đã qua ${-days} ngày';
  return 'Còn $days ngày';
}

/// The month as a strip of day cells with meeting-hour bars, and dates to remember underneath (scenario 4: "tháng này
/// thế nào", "còn mấy ngày tới hạn gửi báo giá").
class MonthScreen extends StatelessWidget {
  const MonthScreen({super.key, required this.c});
  final AppController c;

  static const left = 44.0;
  static const width = 1276.0; // ends at x 1320, left of the mic zone
  static const top = 62.0;
  static const height = 180.0;
  static const maxBar = 108.0;
  static const baseLine = 242.0;
  static const marks = 252.0;

  /// Days of the month that holds [t], as midnights.
  static List<DateTime> monthOf(DateTime t) {
    final n = DateTime(t.year, t.month + 1, 0).day;
    return [for (var d = 1; d <= n; d++) DateTime(t.year, t.month, d)];
  }

  static double cellWidth(int days) => width / days;

  /// Centre x of the cell of [day] in a month of [days] days.
  static double cellCenter(DateTime day, int days) => left + (day.day - .5) * cellWidth(days);

  @override
  Widget build(BuildContext context) {
    final now = c.now;
    final today = dayOf(now);
    final due = c.countdownTo;
    final days = monthOf(due?.start ?? now);
    final n = days.length;
    final cw = cellWidth(n);
    final end = days.last.add(const Duration(days: 1));
    final hours = [for (final d in days) c.plan.meetingHours(d)];
    final busiest = hours.fold(Duration.zero, (a, b) => b > a ? b : a);
    final scale = busiest < const Duration(hours: 1) ? const Duration(hours: 1) : busiest;
    final meetings = days.fold(0, (s, d) => s + c.plan.meetingCount(d));
    final total = hours.fold(Duration.zero, (a, b) => a + b);
    final dueDay = due == null ? null : dayOf(due.start);
    final markList = c.plan.deadlines(days.first, end);

    final String title;
    final String meta;
    if (due == null) {
      title = 'THÁNG ${days.first.month} · ${days.first.year}';
      meta = '$meetings cuộc họp · ${durationVi(total)} họp';
    } else {
      title = due.title.toUpperCase();
      meta = '${daysLeftVi(daysBetween(today, due.start))} · ${shortDate(due.start)}';
    }

    bool inSpan(DateTime d) => dueDay != null && !d.isBefore(today) && !d.isAfter(dueDay);

    return Sky(
      kind: due == null ? SkyKind.at(now) : SkyKind.done,
      glowX: dueDay == null || dueDay.month != days.first.month ? 740 : cellCenter(dueDay, n),
      child: Stack(
        children: [
          Positioned(
            left: left,
            top: 22,
            width: width,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(title, style: eyebrow(color: due == null ? Ink.hot : Ink.cool)),
                const SizedBox(width: 18),
                Expanded(
                  child: Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle(due == null ? 16 : 20),
                  ),
                ),
              ],
            ),
          ),
          // The span from today to the deadline.
          if (dueDay != null)
            for (final d in days)
              if (inSpan(d))
                Positioned(
                  key: ValueKey('span-${d.day}'),
                  left: left + (d.day - 1) * cw,
                  top: top,
                  width: cw,
                  height: height,
                  child: const ColoredBox(color: Color(0x2286D8CC)),
                ),
          for (final (i, d) in days.indexed)
            Positioned(
              key: ValueKey('month-day-${d.day}'),
              left: left + i * cw,
              top: top,
              width: cw,
              height: height,
              child: Opacity(
                opacity: d.isBefore(today) ? .4 : 1,
                child: _Cell(
                  day: d,
                  bar: maxBar * (hours[i].inMinutes / scale.inMinutes).clamp(0.0, 1.0),
                  today: sameDay(d, today),
                  due: dueDay != null && sameDay(d, dueDay),
                ),
              ),
            ),
          Positioned(
            left: left,
            top: baseLine,
            width: width,
            height: 1,
            child: const ColoredBox(color: Ink.hair),
          ),
          for (final m in markList)
            Positioned(
              key: ValueKey('mark-${m.id}'),
              left: cellCenter(m.start, n) - 4,
              top: marks,
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: Ink.cool, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${m.start.day} ${m.title}',
                    style: ts(
                      14,
                      weight: due?.id == m.id ? FontWeight.w600 : FontWeight.w400,
                      color: due?.id == m.id ? Ink.cool : Ink.dim,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.day, required this.bar, required this.today, required this.due});
  final DateTime day;
  final double bar;
  final bool today;
  final bool due;

  @override
  Widget build(BuildContext context) {
    final weekend = day.weekday >= DateTime.saturday;
    final Border? border = due
        ? Border.all(color: Ink.cool, width: 1.5)
        : today
        ? Border.all(color: Ink.hot, width: 1.5)
        : null;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(border: border, borderRadius: BorderRadius.circular(6)),
      child: Column(
        children: [
          const SizedBox(height: 6),
          Text(
            '${day.day}',
            style: ts(
              14,
              weight: today || due ? FontWeight.w600 : FontWeight.w400,
              color: today ? Ink.hot : (weekend ? Ink.faint : Ink.dim),
            ),
          ),
          const Spacer(),
          Container(
            key: ValueKey('bar-${day.day}'),
            width: 14,
            height: bar,
            decoration: BoxDecoration(
              color: today ? Ink.hot : (due ? Ink.cool : const Color(0x8CF2EEE6)),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ),
        ],
      ),
    );
  }
}
