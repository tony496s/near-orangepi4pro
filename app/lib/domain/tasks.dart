import '../core/clock.dart';
import '../core/vi_format.dart';
import 'day_plan.dart';
import 'intent/vi_text.dart';
import 'models.dart';

/// Something open that "xong việc …" can tick off: a note, a reminder, or a calendar deadline.
enum TaskKind { note, reminder, deadline }

class OpenTask {
  const OpenTask({required this.id, required this.kind, required this.title, this.due});

  /// Note id, reminder id, or calendar event id.
  final String id;
  final TaskKind kind;

  /// "Gửi báo giá cho khách" (a deadline titled "Hạn gửi báo giá cho khách" loses its "Hạn ").
  final String title;

  /// Deadline start or reminder time; null for a note.
  final DateTime? due;

  @override
  bool operator ==(Object other) => other is OpenTask && other.id == id && other.kind == kind;
  @override
  int get hashCode => Object.hash(id, kind);
  @override
  String toString() => 'OpenTask($kind $id "$title")';
}

/// How far ahead calendar deadlines count as open tasks.
const deadlineHorizon = Duration(days: 14);

/// A deadline's task title: "Hạn gửi báo giá cho khách" -> "Gửi báo giá cho khách".
String deadlineTaskTitle(String eventTitle) {
  final m = RegExp(r'^\s*(hạn chót|hạn)\s+', caseSensitive: false).firstMatch(eventTitle);
  final rest = m == null ? eventTitle.trim() : eventTitle.substring(m.end).trim();
  return rest.isEmpty ? eventTitle : capitalize(rest);
}

/// Open notes, open reminders, then calendar deadlines from the start of today to [deadlineHorizon] ahead that are not
/// in [doneEvents]. Ordered by when they are due (notes, which have no due time, last).
List<OpenTask> openTasksOf({
  required List<Note> notes,
  required List<Reminder> reminders,
  required DayPlan plan,
  required Set<String> doneEvents,
  required DateTime now,
}) {
  final from = dayOf(now);
  final to = from.add(deadlineHorizon + const Duration(days: 1));
  final dated = <OpenTask>[
    for (final r in reminders)
      if (!r.done) OpenTask(id: r.id, kind: TaskKind.reminder, title: r.text, due: r.at),
    for (final e in plan.deadlines(from, to))
      if (!doneEvents.contains(e.id)) OpenTask(id: e.id, kind: TaskKind.deadline, title: deadlineTaskTitle(e.title), due: e.start),
  ]..sort((a, b) => a.due!.compareTo(b.due!));
  return [
    ...dated,
    for (final n in notes)
      if (!n.done) OpenTask(id: n.id, kind: TaskKind.note, title: n.text),
  ];
}

String _weekdayLower(DateTime t) {
  final w = weekdayName(t);
  return t.weekday == DateTime.sunday ? w : 'thứ ${w.substring(4)}';
}

/// "Hạn thứ Sáu 20/11", "Hạn hôm nay lúc 10:00", "Nhắc lúc 15:00", "Ghi nhanh".
String dueLine(OpenTask task, DateTime now) {
  final d = task.due;
  if (d == null) return 'Ghi nhanh';
  final today = sameDay(d, now);
  final tomorrow = sameDay(d, dayOf(now).add(const Duration(days: 1)));
  final when = today
      ? 'hôm nay lúc ${hhmm(d)}'
      : tomorrow
          ? 'ngày mai ${d.day}/${d.month}'
          : '${_weekdayLower(d)} ${d.day}/${d.month}';
  return task.kind == TaskKind.deadline ? 'Hạn $when' : 'Nhắc ${today ? 'lúc ${hhmm(d)}' : when}';
}

Set<String> _terms(String text) {
  final t = tokenize(text);
  return {...t, for (var i = 0; i + 1 < t.length; i++) '${t[i]} ${t[i + 1]}'};
}

/// The share of [query]'s words and word pairs found in [title], 0..1. Word pairs matter in Vietnamese: "báo giá"
/// (a quote) and "báo cáo" (a report) share a syllable, not a word.
double matchScore(String query, String title) {
  final q = _terms(query);
  if (q.isEmpty) return 0;
  final t = _terms(title);
  return q.where(t.contains).length / q.length;
}

/// What a sentence names among the open tasks.
sealed class TaskMatch {
  const TaskMatch();
}

final class TaskFound extends TaskMatch {
  const TaskFound(this.task);
  final OpenTask task;
}

/// Two tasks scored about the same (STT heard "báo cáo" for "báo giá"): ask, do not guess. Best first.
final class TaskUnsure extends TaskMatch {
  const TaskUnsure(this.options);
  final List<OpenTask> options;
}

final class TaskNotFound extends TaskMatch {
  const TaskNotFound();
}

/// Below this a task is not a candidate at all.
const minMatchScore = .5;

/// A runner-up at or above this share of the best score makes the match unsure.
const unsureRatio = .75;

TaskMatch matchTask(String query, List<OpenTask> tasks) {
  final scored = [
    for (final (i, t) in tasks.indexed) (t, matchScore(query, t.title), i),
  ]..sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$3.compareTo(b.$3));
  if (scored.isEmpty || scored.first.$2 < minMatchScore) return const TaskNotFound();
  final best = scored.first.$2;
  final close = scored.where((s) => s.$2 >= minMatchScore && s.$2 >= best * unsureRatio).toList();
  if (close.length == 1) return TaskFound(close.first.$1);
  return TaskUnsure([close[0].$1, close[1].$1]);
}
