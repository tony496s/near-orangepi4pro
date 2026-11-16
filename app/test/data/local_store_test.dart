import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/data/local_store.dart';
import 'package:near_app/domain/models.dart';

import '../support/fakes.dart';

void main() {
  final t = DateTime(2026, 11, 16, 14, 12);

  StoredState sample() => StoredState(
        notes: [Note(id: 'n1', text: 'Mua sữa', createdAt: t)],
        reminders: [Reminder(id: 'r1', text: 'Gọi chị Lan', at: t.add(const Duration(minutes: 48)), createdAt: t)],
        timer: ActiveTimer(startedAt: t, duration: const Duration(minutes: 25), focus: true),
        sessions: [FocusSession(start: t, end: t.add(const Duration(minutes: 25)), completed: true)],
        lastRecapDay: '2026-11-15',
      );

  test('missing file loads as empty', () async {
    final s = await tempStore().load();
    expect(s.notes, isEmpty);
    expect(s.timer, isNull);
  });

  test('round trip keeps everything', () async {
    final store = tempStore();
    await store.save(sample());
    final s = await store.load();
    expect(s.notes.single.text, 'Mua sữa');
    expect(s.reminders.single.at, t.add(const Duration(minutes: 48)));
    expect(s.timer!.focus, isTrue);
    expect(s.timer!.duration, const Duration(minutes: 25));
    expect(s.sessions.single.completed, isTrue);
    expect(s.lastRecapDay, '2026-11-15');
    expect(File('${store.file.path}.tmp').existsSync(), isFalse, reason: 'temp file renamed into place');
  });

  test('serialized saves: the last one wins', () async {
    final store = tempStore();
    final a = sample();
    final b = sample()..notes.add(Note(id: 'n2', text: 'Đặt phòng', createdAt: t));
    await Future.wait([store.save(a), store.save(b)]);
    expect((await store.load()).notes.length, 2);
  });

  test('corrupt file is moved aside and the strip starts empty', () async {
    final store = tempStore();
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString('{not json');
    final logs = <String>[];
    final s = await LocalStore(store.file, log: logs.add).load();
    expect(s.notes, isEmpty);
    expect(File('${store.file.path}.bad').readAsStringSync(), '{not json');
    expect(store.file.existsSync(), isFalse);
    expect(logs.single, contains('unreadable'));
  });

  test('save failure is reported to the caller', () async {
    final dir = Directory.systemTemp.createTempSync('near_ro');
    final blocker = File('${dir.path}/blocker')..writeAsStringSync('x');
    final store = LocalStore(File('${blocker.path}/state.json')); // parent is a file: cannot create
    await expectLater(store.save(sample()), throwsA(isA<FileSystemException>()));
    // The queue keeps working after a failure.
    final ok = tempStore();
    await ok.save(sample());
  });

  test('prune drops old sessions and old done reminders only', () {
    final s = StoredState(
      sessions: [
        FocusSession(start: t.subtract(const Duration(days: 20)), end: t.subtract(const Duration(days: 20)), completed: true),
        FocusSession(start: t, end: t, completed: true),
      ],
      reminders: [
        Reminder(id: 'old', text: 'x', at: t, createdAt: t, doneAt: t.subtract(const Duration(days: 8))),
        Reminder(id: 'open', text: 'y', at: t.subtract(const Duration(days: 30)), createdAt: t),
      ],
    )..prune(t);
    expect(s.sessions.length, 1);
    expect(s.reminders.map((r) => r.id), ['open']);
  });

  test('dayKey', () => expect(dayKey(t), '2026-11-16'));
}
