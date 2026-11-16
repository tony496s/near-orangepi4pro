import 'dart:async';
import 'dart:io';

import 'package:near_app/core/clock.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/data/local_store.dart';
import 'package:near_app/domain/models.dart';
import 'package:near_app/voice/voice_client.dart';

class FakeVoice implements VoiceLink {
  final _events = StreamController<VoiceEvent>.broadcast(sync: true);
  bool isReady = true;
  final sent = <String>[];

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  bool get ready => isReady;

  @override
  void listen(String id) => sent.add('listen $id');

  @override
  void cancel() => sent.add('cancel');

  @override
  void finish() => sent.add('finish');

  @override
  void chime(String name) => sent.add('chime $name');

  void emit(VoiceEvent e) => _events.add(e);
}

class FixedCalendar implements CalendarSource {
  FixedCalendar(this.events);
  final List<CalendarEvent> events;

  @override
  Future<List<CalendarEvent>> fetch(DateTime from, DateTime to) async =>
      events.where((e) => !e.start.isBefore(from) && e.start.isBefore(to)).toList();
}

/// A store in a fresh temporary directory.
LocalStore tempStore() => LocalStore(File('${Directory.systemTemp.createTempSync('near_test').path}/state.json'));

CalendarEvent ev(String id, String title, DateTime start, int minutes, {EventKind kind = EventKind.meeting}) =>
    CalendarEvent(id: id, title: title, start: start, end: start.add(Duration(minutes: minutes)), kind: kind, place: 'Phòng 3');

FakeClock clockAt(int hour, [int minute = 0]) => FakeClock(DateTime(2026, 11, 16, hour, minute));
