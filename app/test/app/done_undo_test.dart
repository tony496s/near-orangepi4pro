import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/data/local_store.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/models.dart';
import 'package:near_app/domain/tasks.dart';
import 'package:near_app/voice/voice_client.dart';

import '../support/fakes.dart';

void main() {
  final day = DateTime(2026, 11, 16);
  final events = [
    ev('stand', 'Họp đứng', day.add(const Duration(hours: 9)), 15),
    ev('quote', 'Hạn gửi báo giá cho khách', day.add(const Duration(days: 4, hours: 10)), 0, kind: EventKind.deadline),
    ev('report', 'Hạn gửi báo cáo tuần', day.add(const Duration(days: 3, hours: 17)), 0, kind: EventKind.deadline),
  ];

  late FakeClock clock;
  late FakeVoice voice;
  late LocalStore store;
  late AppController c;

  Future<void> make({LocalStore? withStore}) async {
    clock = clockAt(14, 35);
    voice = FakeVoice();
    store = withStore ?? tempStore();
    c = AppController(clock: clock, store: store, calendar: FixedCalendar(events), voice: voice, heardHold: Duration.zero, log: (_) {});
    await c.start(ticker: false);
  }

  void run(Duration d) {
    for (var s = 0; s < d.inSeconds; s++) {
      clock.advance(const Duration(seconds: 1));
      c.tick();
    }
  }

  void say(String text) {
    c.talk();
    final id = voice.sent.last.split(' ').last;
    voice.emit(VoiceFinal(id, text));
  }

  test('a clear match is marked done at once; the done screen and its undo go after 8 s', () async {
    await make();
    say('xong việc gửi báo giá cho khách');
    expect(c.doneChoice, isNull);
    final d = c.doneUndo!;
    expect(d.task.id, 'quote');
    expect(d.next?.title, 'Gửi báo cáo tuần');
    expect(d.left, 1);
    expect(c.doneEvents, {'quote'});
    expect(c.openTasks.map((t) => t.id), ['report']);
    run(const Duration(seconds: 7));
    expect(c.doneUndo, isNotNull);
    expect(d.remaining(c.now), closeTo(1 / 8, 1e-9));
    run(const Duration(seconds: 1));
    expect(c.doneUndo, isNull, reason: 'gone after 8 s');
    expect(c.doneEvents, {'quote'}, reason: 'still done');
    expect(c.screen, Screen.home);
  });

  test('"Hoàn tác" opens the task again and says so', () async {
    await make();
    say('gửi báo giá xong rồi');
    run(const Duration(seconds: 3));
    c.undoDone();
    expect(c.doneUndo, isNull);
    expect(c.doneEvents, isEmpty);
    expect(c.openTasks.map((t) => t.id), ['report', 'quote']);
    expect(c.flash?.eyebrow, 'ĐÃ HOÀN TÁC');
    expect(c.flash?.title, 'Gửi báo giá cho khách');
    expect(c.flash?.meta, 'Vẫn còn mở · Hạn thứ Sáu 20/11');
  });

  test('"báo cáo" for "báo giá": asks with both tasks; a tap marks the chosen one; then undo', () async {
    await make();
    say('xong việc gửi báo cáo cho khách');
    final q = c.doneChoice!;
    expect(q.heard, 'Xong việc gửi báo cáo cho khách');
    expect(q.options.map((t) => t.id), ['quote', 'report']);
    expect(c.doneEvents, isEmpty, reason: 'nothing marked before the answer');
    c.chooseDone(q.options.first);
    expect(c.doneChoice, isNull);
    expect(c.doneUndo?.task.id, 'quote');
    expect(c.doneEvents, {'quote'});
    c.undoDone();
    expect(c.doneEvents, isEmpty);
  });

  test('"Nói lại" drops the question and listens again; the question closes by itself after 30 s', () async {
    await make();
    say('xong việc gửi báo cáo cho khách');
    final listens = voice.sent.where((m) => m.startsWith('listen')).length;
    c.retryDone();
    expect(c.doneChoice, isNull);
    expect(c.listening?.phase, ListenPhase.listening);
    expect(voice.sent.where((m) => m.startsWith('listen')), hasLength(listens + 1));
    c.cancelTalk();
    say('xong việc gửi báo cáo cho khách');
    run(AppController.choiceFor);
    expect(c.doneChoice, isNull);
    expect(c.doneEvents, isEmpty);
  });

  test('no match: a short "KHÔNG THẤY"', () async {
    await make();
    say('xong việc mua vé máy bay');
    expect(c.doneChoice, isNull);
    expect(c.doneUndo, isNull);
    expect(c.flash?.eyebrow, 'KHÔNG THẤY');
    expect(c.flash?.title, 'Không có việc “mua vé máy bay”');
  });

  test('notes and reminders are tasks too; undo opens them again', () async {
    await make();
    c.run(const AddNote('Mua sữa và trứng'));
    c.run(AddReminder('Gọi chị Lan', day.add(const Duration(hours: 15))));
    c.run(const MarkDone('mua sữa'));
    expect(c.notes.single.done, isTrue);
    c.undoDone();
    expect(c.notes.single.done, isFalse);
    c.run(const MarkDone('gọi chị lan'));
    expect(c.reminders.single.done, isTrue);
    run(const Duration(minutes: 30));
    expect(c.alert, isNull, reason: 'a reminder marked done does not fire');
  });

  test('a new command closes the done screen; deadline done state survives a restart', () async {
    await make();
    c.run(const MarkDone('gửi báo giá'));
    expect(c.doneUndo, isNotNull);
    c.run(const WhatTime());
    expect(c.doneUndo, isNull);
    await store.idle;
    await make(withStore: store);
    expect(c.doneEvents, {'quote'});
    expect(c.openTasks.map((t) => t.kind), [TaskKind.deadline]);
  });
}
