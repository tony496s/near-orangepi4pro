import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/day_plan.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/intent/parser.dart';
import 'package:near_app/domain/models.dart';
import 'package:near_app/domain/tasks.dart';

import '../support/fakes.dart';

void main() {
  final now = DateTime(2026, 11, 16, 14, 35);
  Command? p(String s) => parseCommand(s, now);
  Matcher done(String query) => isA<MarkDone>().having((c) => c.query, 'query', query);

  group('parser: mark done by voice', () {
    test('the three demo sentences', () {
      expect(p('xong việc gửi báo giá cho khách'), done('gửi báo giá cho khách'));
      expect(p('đánh dấu xong gửi báo giá'), done('gửi báo giá'));
      expect(p('gửi báo giá xong rồi'), done('gửi báo giá'));
    });

    test('STT and typed variants', () {
      expect(p('XONG VIỆC GỬI BÁO CÁO CHO KHÁCH'), done('gửi báo cáo cho khách'));
      expect(p('Xong việc gửi báo giá cho khách.'), done('gửi báo giá cho khách'));
      expect(p('đánh dấu gửi báo giá là xong'), done('gửi báo giá'));
      expect(p('đã gửi báo giá xong rồi nhé'), done('gửi báo giá'));
      expect(p('làm xong việc gửi báo cáo tuần'), done('gửi báo cáo tuần'));
      expect(p('đã hoàn thành việc gửi báo giá'), done('gửi báo giá'));
    });

    test('keeps the heard sentence for the choice screen', () {
      final c = p('xong việc gửi báo cáo cho khách') as MarkDone;
      expect(c.heard, 'Xong việc gửi báo cáo cho khách');
    });

    test('"xong" alone names no task; other rules keep their sentences', () {
      expect(p('xong'), isNull);
      expect(p('xong rồi'), isNull);
      expect(p('xong việc'), isNull);
      expect(p('đánh dấu xong'), isNull);
      expect(p('ghi lại gửi báo giá xong rồi'), isA<AddNote>(), reason: 'notes keep their words');
      expect(p('nhắc anh gửi báo giá khi họp xong'), isA<AddReminder>());
      expect(p('tập trung đến khi xong'), isA<StartTimer>(), reason: 'timer sentences stay timers');
      expect(p('còn mấy ngày tới hạn gửi báo giá'), const DaysUntil('gửi báo giá'));
      expect(p('hẹn giờ 10 phút'), const StartTimer(Duration(minutes: 10), focus: false));
    });
  });

  group('open tasks', () {
    final plan = DayPlan([
      ev('due', 'Hạn gửi báo giá cho khách', DateTime(2026, 11, 20, 10), 0, kind: EventKind.deadline),
      ev('rep', 'Hạn gửi báo cáo tuần', DateTime(2026, 11, 19, 17), 0, kind: EventKind.deadline),
      ev('old', 'Hạn cũ', DateTime(2026, 11, 13, 10), 0, kind: EventKind.deadline),
      ev('far', 'Hạn xa', DateTime(2026, 12, 15, 10), 0, kind: EventKind.deadline),
      ev('m', 'Họp đứng', DateTime(2026, 11, 17, 9), 15),
    ]);
    final note = Note(id: 'n1', text: 'Mua sữa', createdAt: now);
    final doneNote = Note(id: 'n2', text: 'Đặt phòng', createdAt: now, doneAt: now);
    final rem = Reminder(id: 'r1', text: 'Gọi chị Lan', at: DateTime(2026, 11, 16, 15), createdAt: now);

    test('notes, reminders and deadlines from today to two weeks ahead, most urgent first, "Hạn " dropped', () {
      final tasks = openTasksOf(notes: [note, doneNote], reminders: [rem], plan: plan, doneEvents: {}, now: now);
      expect(tasks.map((t) => (t.kind, t.title)), [
        (TaskKind.reminder, 'Gọi chị Lan'),
        (TaskKind.deadline, 'Gửi báo cáo tuần'),
        (TaskKind.deadline, 'Gửi báo giá cho khách'),
        (TaskKind.note, 'Mua sữa'),
      ]);
      final open = openTasksOf(notes: [], reminders: [], plan: plan, doneEvents: {'due'}, now: now);
      expect(open.map((t) => t.id), ['rep'], reason: 'a deadline marked done is not open');
    });

    test('due lines as in the demo', () {
      final tasks = openTasksOf(notes: [note], reminders: [rem], plan: plan, doneEvents: {}, now: now);
      expect(tasks.map((t) => dueLine(t, now)), ['Nhắc lúc 15:00', 'Hạn thứ Năm 19/11', 'Hạn thứ Sáu 20/11', 'Ghi nhanh']);
      expect(dueLine(OpenTask(id: 'x', kind: TaskKind.deadline, title: 'X', due: DateTime(2026, 11, 16, 10)), now),
          'Hạn hôm nay lúc 10:00');
      expect(dueLine(OpenTask(id: 'x', kind: TaskKind.deadline, title: 'X', due: DateTime(2026, 11, 22, 10)), now),
          'Hạn Chủ Nhật 22/11');
      expect(deadlineTaskTitle('Hạn chót nộp thuế'), 'Nộp thuế');
      expect(deadlineTaskTitle('Release 1.2'), 'Release 1.2');
    });
  });

  group('matching', () {
    const quote = OpenTask(id: 'due', kind: TaskKind.deadline, title: 'Gửi báo giá cho khách');
    const report = OpenTask(id: 'rep', kind: TaskKind.deadline, title: 'Gửi báo cáo tuần');
    const milk = OpenTask(id: 'n1', kind: TaskKind.note, title: 'Mua sữa và trứng trên đường về');
    const tasks = [report, quote, milk];

    test('a clear best match', () {
      expect(matchTask('gửi báo giá cho khách', tasks), isA<TaskFound>().having((m) => m.task, 'task', quote));
      expect(matchTask('gửi báo giá', tasks), isA<TaskFound>().having((m) => m.task, 'task', quote));
      expect(matchTask('báo cáo tuần', tasks), isA<TaskFound>().having((m) => m.task, 'task', report));
      expect(matchTask('gửi báo cáo', tasks), isA<TaskFound>().having((m) => m.task, 'task', report));
      expect(matchTask('mua sữa', tasks), isA<TaskFound>().having((m) => m.task, 'task', milk));
    });

    test('"báo giá" heard as "báo cáo": both tasks half match, so ask, best first', () {
      expect(matchScore('gửi báo cáo cho khách', quote.title), closeTo(6 / 9, 1e-9));
      expect(matchScore('gửi báo cáo cho khách', report.title), closeTo(5 / 9, 1e-9));
      final m = matchTask('gửi báo cáo cho khách', tasks);
      expect(m, isA<TaskUnsure>().having((m) => m.options, 'options', [quote, report]));
    });

    test('no match', () {
      expect(matchTask('họp', tasks), isA<TaskNotFound>());
      expect(matchTask('gửi email', tasks), isA<TaskNotFound>());
      expect(matchTask('gửi báo giá', const []), isA<TaskNotFound>());
    });

    test('more than two close: the two best', () {
      const note = OpenTask(id: 'n2', kind: TaskKind.note, title: 'Gửi báo giá cho khách mới');
      final m = matchTask('gửi báo giá cho khách', [report, quote, note]) as TaskUnsure;
      expect(m.options, [quote, note]);
    });
  });
}
