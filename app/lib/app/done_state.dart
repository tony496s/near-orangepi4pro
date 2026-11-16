import '../domain/tasks.dart';

/// "Việc nào đã xong?": what was heard matched two open tasks about equally, so the strip asks with two big buttons.
class DoneChoice {
  const DoneChoice({required this.heard, required this.options, required this.until});

  /// The sentence as heard ("Xong việc gửi báo cáo cho khách").
  final String heard;

  /// Two tasks, best match first.
  final List<OpenTask> options;

  /// Closes by itself then, nothing marked.
  final DateTime until;
}

/// A task just marked done, with the undo window: the done screen shows until [until].
class DoneUndo {
  const DoneUndo({required this.task, required this.since, required this.until, this.next, this.left = 0});

  final OpenTask task;
  final DateTime since;
  final DateTime until;

  /// The most urgent task still open ("Còn lại: …"), and how many are.
  final OpenTask? next;
  final int left;

  /// 1 when just marked, 0 when the undo is gone.
  double remaining(DateTime now) {
    final total = until.difference(since).inMilliseconds;
    if (total <= 0) return 0;
    return (until.difference(now).inMilliseconds / total).clamp(0.0, 1.0);
  }
}
