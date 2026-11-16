import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/data/local_store.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/voice/voice_client.dart';

import '../support/fakes.dart';

void main() {
  final day = DateTime(2026, 11, 16);
  final events = [
    ev('stand', 'Họp đứng', day.add(const Duration(hours: 9)), 15),
    ev('design', 'Họp thiết kế', day.add(const Duration(hours: 10, minutes: 30)), 75),
  ];

  late FakeClock clock;
  late FakeVoice voice;
  late LocalStore store;
  late AppController c;

  Future<AppController> make({int hour = 9, int minute = 20, LocalStore? withStore}) async {
    clock = clockAt(hour, minute);
    voice = FakeVoice();
    store = withStore ?? tempStore();
    c = AppController(clock: clock, store: store, calendar: FixedCalendar(events), voice: voice, heardHold: Duration.zero, log: (_) {});
    await c.start(ticker: false);
    return c;
  }

  /// Moves the clock forward one second at a time, ticking like the app does.
  void run(Duration d) {
    for (var s = 0; s < d.inSeconds; s++) {
      clock.advance(const Duration(seconds: 1));
      c.tick();
    }
  }

  /// One voice round trip: tap, speak, final transcript.
  void say(String text) {
    c.talk();
    final id = voice.sent.last.split(' ').last;
    voice.emit(VoiceProcessing(id));
    voice.emit(VoiceFinal(id, text, sttMs: 170));
  }

  group('scenario 1: keeping the morning rhythm', () {
    test('a spoken focus session runs, ends with an alert and a chime, and offers a break', () async {
      await make();
      c.talk();
      expect(c.listening!.phase, ListenPhase.listening);
      expect(voice.sent.last, 'listen l1');
      voice.emit(const VoiceLevel(-28));
      expect(c.listening!.level, -28);
      voice.emit(const VoiceProcessing('l1'));
      expect(c.listening!.phase, ListenPhase.thinking);
      voice.emit(const VoiceFinal('l1', 'HẸN GIỜ HAI MƯƠI LĂM PHÚT ĐỂ TẬP TRUNG'));
      expect(c.listening, isNull);
      expect(c.focusing, isTrue);
      expect(c.timer!.endsAt, day.add(const Duration(hours: 9, minutes: 45)));

      run(const Duration(minutes: 25));
      expect(c.focusing, isFalse);
      final a = c.alert as TimerDoneAlert;
      expect(a.sessionNumber, 1);
      expect(voice.sent, contains('chime alert'));
      expect(c.sessionsToday.single.completed, isTrue);

      c.alertAction(AlertAction.primary);
      expect(c.alert, isNull);
      expect(c.timer!.focus, isFalse, reason: 'the break is a plain timer');
      expect(c.timer!.duration, const Duration(minutes: 5));
      expect(c.flash!.eyebrow, 'NGHỈ 5 PHÚT');
    });

    test('"tiếp theo là gì" during focus answers in a card without leaving focus', () async {
      await make();
      say('hẹn giờ 25 phút để tập trung');
      run(const Duration(minutes: 18));
      say('TIẾP THEO LÀ GÌ');
      expect(c.focusing, isTrue);
      expect(c.flash!.title, 'Họp thiết kế');
      expect(c.flash!.meta, '10:30 · còn 52 phút · Phòng 3');
    });

    test('meeting soon: highlighted 5 minutes before, with a soft chime, once', () async {
      await make(hour: 10, minute: 24);
      run(const Duration(seconds: 59));
      expect(c.soonEventId, isNull);
      run(const Duration(seconds: 1));
      expect(c.soonEventId, 'design');
      expect(voice.sent.where((s) => s == 'chime soft').length, 1);
      run(const Duration(minutes: 2));
      expect(voice.sent.where((s) => s == 'chime soft').length, 1);
      run(const Duration(minutes: 3));
      expect(c.soonEventId, isNull, reason: 'cleared once the meeting starts');
    });

    test('cancelling a focus session keeps it as not completed', () async {
      await make();
      say('bắt đầu tập trung');
      run(const Duration(minutes: 10));
      say('dừng tập trung');
      expect(c.timer, isNull);
      expect(c.sessions.single.completed, isFalse);
      expect(c.sessionsToday, isEmpty);
    });
  });

  group('scenario 2: quick notes through the end of the day', () {
    test('a note is confirmed in the strip and counted for today', () async {
      await make(hour: 14, minute: 10);
      say('GHI LẠI MUA SỮA VÀ TRỨNG TRÊN ĐƯỜNG VỀ');
      expect(c.notes.single.text, 'Mua sữa và trứng trên đường về');
      expect(c.flash!.eyebrow, 'ĐÃ GHI NHANH');
      expect(c.flash!.meta, '1 việc ghi nhanh hôm nay');
      run(const Duration(seconds: 6));
      expect(c.flash, isNull);
    });

    test('a reminder fires at its time; "10 phút nữa" snoozes it; "Xong" closes it', () async {
      await make(hour: 14, minute: 12);
      say('nhắc anh gọi cho chị Lan lúc ba giờ chiều');
      expect(c.flash!.meta, '15:00 · còn 48 phút');
      run(const Duration(minutes: 48));
      final a = c.alert as ReminderAlert;
      expect(a.reminder.text, 'Gọi cho chị Lan');
      c.alertAction(AlertAction.secondary);
      expect(c.alert, isNull);
      run(const Duration(minutes: 10));
      expect(c.alert, isA<ReminderAlert>(), reason: 'snoozed reminder fires again');
      c.alertAction(AlertAction.primary);
      expect(c.reminders.single.done, isTrue);
      run(const Duration(minutes: 30));
      expect(c.alert, isNull);
    });

    test('a reminder that comes due during focus waits for the end of the session', () async {
      await make(hour: 14, minute: 40);
      say('nhắc anh gọi chị Lan sau 2 phút');
      say('hẹn giờ 5 phút để tập trung');
      run(const Duration(minutes: 3));
      expect(c.alert, isNull);
      run(const Duration(minutes: 2));
      expect(c.alert, isA<TimerDoneAlert>());
      c.alertAction(AlertAction.secondary);
      expect(c.alert, isA<ReminderAlert>(), reason: 'shown right after the focus session');
    });

    test('a reminder said without a time asks when', () async {
      await make(hour: 14, minute: 0);
      say('nhắc anh mua quà sinh nhật mẹ');
      expect(c.askTime!.text, 'Mua quà sinh nhật mẹ');
      c.answerAskTime(const Duration(hours: 1));
      expect(c.askTime, isNull);
      expect(c.reminders.single.at, day.add(const Duration(hours: 15)));
    });

    test('recap shows by itself at 17:50 and returns home after a minute untouched', () async {
      await make(hour: 17, minute: 49);
      run(const Duration(minutes: 1));
      expect(c.screen, Screen.recap);
      run(const Duration(seconds: 59));
      expect(c.screen, Screen.recap);
      run(const Duration(seconds: 1));
      expect(c.screen, Screen.home);
      run(const Duration(minutes: 5));
      expect(c.screen, Screen.home, reason: 'once a day');
    });

    test('recap can be ticked off: toggling a note marks it done and back', () async {
      await make(hour: 17);
      say('ghi lại đặt phòng họp thứ năm');
      final id = c.notes.single.id;
      c.toggleDone(id);
      expect(c.notes.single.done, isTrue);
      c.toggleDone(id);
      expect(c.notes.single.done, isFalse);
    });

    test('swipe up from the recap shows tomorrow, swipe down comes back home', () async {
      await make(hour: 17, minute: 52);
      expect(c.screen, Screen.recap, reason: 'started inside the recap window');
      c.swipeUp();
      expect(c.screen, Screen.tomorrow);
      c.swipeDown();
      expect(c.screen, Screen.home);
    });
  });

  group('night', () {
    test('the screen goes dark at 23:00; a tap shows the clock for 10 seconds', () async {
      await make(hour: 22, minute: 59);
      expect(c.night, isFalse);
      run(const Duration(minutes: 1));
      expect(c.night, isTrue);
      c.tapNight();
      expect(c.peeking, isTrue);
      run(const Duration(seconds: 10));
      expect(c.peeking, isFalse);
    });

    test('"bật màn" at night keeps the screen on until the morning', () async {
      await make(hour: 23, minute: 10);
      expect(c.night, isTrue);
      c.run(const ScreenOnCommand());
      expect(c.night, isFalse);
      run(const Duration(hours: 1));
      expect(c.night, isFalse);
    });

    test('"tắt màn" during the day: dark until "bật màn"', () async {
      await make(hour: 14);
      say('tắt màn hình đi');
      expect(c.night, isTrue);
      expect(c.manualNight, isTrue);
      run(const Duration(minutes: 30));
      expect(c.night, isTrue);
      say('bật màn');
      expect(c.night, isFalse);
    });
  });

  group('voice problems', () {
    test('not understood shows what was heard, then closes by itself', () async {
      await make();
      say('thời tiết hôm nay thế nào');
      expect(c.listening!.phase, ListenPhase.notUnderstood);
      expect(c.listening!.text, 'thời tiết hôm nay thế nào');
      run(const Duration(seconds: 6));
      expect(c.listening, isNull);
    });

    test('service not ready: the mic says so instead of listening', () async {
      await make();
      voice.isReady = false;
      c.talk();
      expect(c.listening!.phase, ListenPhase.unavailable);
      expect(voice.sent.where((s) => s.startsWith('listen')), isEmpty);
    });

    test('silence and disconnects end the listening state', () async {
      await make();
      c.talk();
      voice.emit(const VoiceTimeout('l1'));
      expect(c.listening!.phase, ListenPhase.noSpeech);
      c.talk();
      voice.emit(const VoiceDisconnected());
      expect(c.listening!.phase, ListenPhase.unavailable);
    });

    test('a tap while listening finishes: what was said is used', () async {
      // On the board people tapped again to "send", and the tap used to cancel: the sentence was lost.
      await make();
      c.talk();
      c.tapOverlay();
      expect(voice.sent.last, 'finish');
      expect(c.listening!.phase, ListenPhase.thinking);
      voice.emit(const VoiceProcessing('l1'));
      expect(c.listening!.phase, ListenPhase.thinking);
      voice.emit(const VoiceFinal('l1', 'hẹn giờ 10 phút'));
      expect(c.timer!.duration, const Duration(minutes: 10));
    });

    test('a tap to finish with nothing said closes quietly', () async {
      await make();
      c.talk();
      c.tapOverlay();
      voice.emit(const VoiceTimeout('l1'));
      expect(c.listening, isNull);
    });

    test('a timeout without a tap still says nothing was heard', () async {
      await make();
      c.talk();
      voice.emit(const VoiceTimeout('l1'));
      expect(c.listening!.phase, ListenPhase.noSpeech);
    });

    test('finishing gives up if the service never answers', () async {
      await make();
      c.talk();
      c.tapOverlay();
      clock.advance(AppController.finishTimeout);
      c.tick();
      expect(c.listening, isNull);
    });

    test('a tap on a notice closes it without talking to the service', () async {
      await make();
      c.talk();
      voice.emit(const VoiceTimeout('l1'));
      final before = voice.sent.length;
      c.tapOverlay();
      expect(c.listening, isNull);
      expect(voice.sent.length, before);
    });

    test('a late transcript from an earlier request is ignored', () async {
      await make();
      c.talk();
      c.cancelTalk();
      expect(voice.sent.last, 'cancel');
      c.talk();
      voice.emit(const VoiceFinal('l1', 'hẹn giờ 10 phút'));
      expect(c.timer, isNull);
      expect(c.listening!.phase, ListenPhase.listening);
    });
  });

  group('wake word', () {
    test('"Hey Near" starts a listen like the mic, and its words run as a command', () async {
      await make();
      voice.emit(const VoiceWake('HEY_NEAR'));
      expect(c.listening!.phase, ListenPhase.listening);
      expect(voice.sent.last, 'listen l1');
      voice.emit(const VoiceProcessing('l1'));
      voice.emit(const VoiceFinal('l1', 'Đặt hẹn giờ 15 phút.', engine: 'deepgram'));
      expect(c.timer!.duration, const Duration(minutes: 15));
    });

    test('a wake while already listening does not start another listen', () async {
      await make();
      c.talk();
      voice.emit(const VoiceWake('HEY_NEAR'));
      expect(voice.sent.where((s) => s.startsWith('listen')), ['listen l1']);
      expect(c.listening!.id, 'l1');
    });

    test('a wake over a notice (e.g. not understood) starts a new listen', () async {
      await make();
      say('thời tiết hôm nay thế nào');
      expect(c.listening!.phase, ListenPhase.notUnderstood);
      voice.emit(const VoiceWake('HEY_NEAR'));
      expect(c.listening!.phase, ListenPhase.listening);
    });

    test('the service is told: on by day, off at night and during focus, on again after', () async {
      await make(hour: 22, minute: 59);
      expect(voice.wakes, [true]);
      run(const Duration(minutes: 1));
      expect(c.night, isTrue);
      expect(voice.wakes, [true, false]);
      voice.emit(const VoiceWake('HEY_NEAR'));
      expect(c.listening, isNull, reason: 'a late wake at night is ignored');
      c.run(const ScreenOnCommand());
      expect(voice.wakes, [true, false, true]);
      say('hẹn giờ 1 phút để tập trung');
      expect(c.focusing, isTrue);
      expect(voice.wakes.last, isFalse);
      voice.emit(const VoiceWake('HEY_NEAR'));
      expect(c.listening, isNull);
      run(const Duration(minutes: 1, seconds: 1));
      expect(c.focusing, isFalse);
      expect(voice.wakes.last, isTrue);
    });

    test('told again after the service reconnects, and not while it is down', () async {
      await make();
      expect(voice.wakes, [true]);
      run(const Duration(seconds: 3));
      expect(voice.wakes, [true], reason: 'only changes are sent');
      voice.isReady = false;
      voice.emit(const VoiceDisconnected());
      run(const Duration(seconds: 2));
      expect(voice.wakes, [true]);
      voice.isReady = true;
      voice.emit(const VoiceReady('m', stt: 'deepgram', wake: 'sherpa-kws'));
      expect(voice.wakes, [true, true]);
    });
  });

  test('timers, notes and reminders survive a restart', () async {
    await make();
    say('hẹn giờ 25 phút để tập trung');
    say('ghi lại mua sữa');
    await store.idle;
    final again = AppController(clock: clock, store: LocalStore(store.file), calendar: FixedCalendar(events), voice: FakeVoice(), log: (_) {});
    await again.start(ticker: false);
    expect(again.focusing, isTrue);
    expect(again.timer!.endsAt, day.add(const Duration(hours: 9, minutes: 45)));
    expect(again.notes.single.text, 'Mua sữa');
  });

  test('wrong system clock (no NTP yet): no alerts, no night mode', () async {
    clock = FakeClock(DateTime(1970, 1, 1, 23, 30));
    c = AppController(clock: clock, store: tempStore(), calendar: FixedCalendar(events), log: (_) {});
    await c.start(ticker: false);
    expect(c.clockValid, isFalse);
    expect(c.night, isFalse);
  });
}

/// The parser's ScreenOn command, under a name that reads well in a test.
typedef ScreenOnCommand = ScreenOn;
