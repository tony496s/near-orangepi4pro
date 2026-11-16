import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/data/local_store.dart';
import 'package:near_app/domain/strip_layout.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/voice/voice_client.dart';

import '../support/fakes.dart';

void main() {
  final day = DateTime(2026, 11, 16);
  final events = [
    ev('stand', 'Họp đứng', day.add(const Duration(hours: 9)), 15),
    ev('quote', 'Hạn gửi báo giá', day.add(const Duration(days: 4, hours: 10)), 0),
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

  group('home layout (scenario 5)', () {
    test('first start is three columns; "về một cột" and "ba cột" switch and survive a restart', () async {
      await make();
      expect(c.layout, StripLayout.initial);
      say('VỀ MỘT CỘT');
      expect(c.layout.split, isFalse);
      expect(c.screen, Screen.home);
      await store.idle;
      await make(withStore: store);
      expect(c.layout.split, isFalse, reason: 'remembered after a reboot');
      say('CHIA MÀN BA CỘT LỊCH GIÁ VÀNG HẸN GIỜ');
      expect(c.layout, StripLayout.initial);
      expect(c.timer, isNull, reason: '"hẹn giờ" in the list of columns starts no timer');
      await store.idle;
      await make(withStore: store);
      expect(c.layout.split, isTrue);
    });

    test('"đổi cột giữa sang tỷ giá đô la" changes the middle only; the timer keeps running; the set is saved', () async {
      await make();
      say('hẹn giờ 45 phút');
      say('ĐỔI CỘT GIỮA SANG TỶ GIÁ ĐÔ LA');
      expect(c.layout, const StripLayout([Panel.calendar, Panel.fx, Panel.timer]));
      expect(c.timer, isNotNull, reason: 'the timer column runs on');
      expect(c.fx.points.length, 31, reason: 'USD/VND, 30 days back to today');
      expect(c.fx.points.last.at, day);
      final fx = c.fx;
      run(const Duration(minutes: 10));
      expect(identical(c.fx, fx), isTrue, reason: 'read once a day');
      expect(c.screen, Screen.home);
      say('đổi tỷ giá sang giá vàng');
      expect(c.layout, StripLayout.initial, reason: 'the column showing fx');
      say('đổi cột sang tỷ giá');
      expect(c.layout.panels[1], Panel.fx, reason: 'no column named: the middle one');
      await store.idle;
      await make(withStore: store);
      expect(c.layout.panels, const [Panel.calendar, Panel.fx, Panel.timer], reason: 'remembered after a reboot');
    });

    test('"về một cột" says the layout is kept; "chia màn" with names sets the columns', () async {
      await make(hour: 10);
      say('về một cột');
      expect(c.flash!.eyebrow, 'TIẾP THEO');
      expect(c.flash!.title, 'Họp thiết kế');
      expect(c.flash!.meta, endsWith('· đã lưu bố cục ba cột'));
      say('về một cột');
      expect(c.flash, isNull, reason: 'already one column: nothing to keep');
      say('chia màn hai cột lịch và hẹn giờ');
      expect(c.layout, const StripLayout([Panel.calendar, Panel.timer]));
      say('về một cột');
      expect(c.flash!.meta, endsWith('đã lưu bố cục hai cột'));
      say('ba cột');
      expect(c.layout, const StripLayout([Panel.calendar, Panel.timer]), reason: 'no names: the remembered set');
    });

    test('gold comes from the price source for today, up to now', () async {
      await make();
      expect(c.gold.points.last.at, day.add(const Duration(hours: 9, minutes: 20)));
      run(const Duration(minutes: 5));
      expect(c.gold.points.last.at, day.add(const Duration(hours: 9, minutes: 25)), reason: 'refreshed every step');
    });
  });

  group('gold (scenario 3)', () {
    test('an alert just above the price fires once, within minutes, with a chime; "Xem chart" opens the chart', () async {
      await make();
      say('MỞ CHÁT VÀNG');
      expect(c.screen, Screen.gold);
      say('SO VỚI HÔM QUA THÌ SAO');
      expect(c.goldCompare, isTrue);
      final threshold = (c.gold.last + 2).roundToDouble();
      c.run(SetGoldAlert(threshold));
      expect(c.flash!.eyebrow, 'ĐÃ ĐẶT BÁO GIÁ');
      expect(c.goldAlert!.above, isTrue);
      for (var i = 0; i < 300 && c.alert == null; i++) {
        run(const Duration(seconds: 1));
      }
      final a = c.alert;
      expect(a, isA<GoldCrossedAlert>(), reason: 'crossed within 5 minutes');
      expect((a as GoldCrossedAlert).price, greaterThanOrEqualTo(threshold));
      expect(voice.sent, contains('chime alert'));
      expect(c.goldAlert!.fired, isTrue);
      c.alertAction(AlertAction.primary);
      expect(c.screen, Screen.gold);
      run(const Duration(minutes: 3));
      expect(c.alert, isNull, reason: 'fires once');
      await store.idle;
      await make(withStore: store);
      expect(c.goldAlert!.fired, isTrue, reason: 'kept after a restart, not fired again');
    });

    test('"Tắt báo" removes the alert', () async {
      await make();
      c.run(SetGoldAlert((c.gold.last + 1).roundToDouble()));
      for (var i = 0; i < 300 && c.alert == null; i++) {
        run(const Duration(seconds: 1));
      }
      c.alertAction(AlertAction.secondary);
      expect(c.goldAlert, isNull);
    });
  });

  test('on the columns a plain timer ends in its column, a focus session on the whole strip', () async {
    await make();
    say('hẹn giờ 1 phút');
    run(const Duration(seconds: 61));
    expect(c.timerDoneInColumn, isNotNull);
    c.alertAction(AlertAction.secondary);
    say('hẹn giờ 1 phút để tập trung');
    run(const Duration(seconds: 61));
    expect(c.alert, isA<TimerDoneAlert>());
    expect(c.timerDoneInColumn, isNull, reason: 'focus ends with "Nghỉ 5 phút" on the whole strip');
  });

  test('a new timer clears a "hết giờ" still waiting', () async {
    await make();
    say('hẹn giờ 1 phút');
    run(const Duration(seconds: 61));
    expect(c.alert, isA<TimerDoneAlert>());
    say('hẹn giờ 10 phút');
    expect(c.alert, isNull);
    expect(c.timer!.duration, const Duration(minutes: 10));
  });

  group('busy at a time', () {
    test('a meeting in that hour is named with its times; a free hour says what comes after', () async {
      await make(hour: 8);
      say('CHÍN GIỜ SÁNG NAY CÓ HỌP KHÔNG');
      expect(c.flash!.eyebrow, 'LÚC 09:00 · CÓ LỊCH');
      expect(c.flash!.title, 'Họp đứng');
      expect(c.flash!.meta, '09:00–09:15');
      say('mười giờ có lịch gì không');
      expect(c.flash!.eyebrow, 'LÚC 10:00 · CÓ LỊCH', reason: 'Họp thiết kế starts at 10:30, inside the hour');
      expect(c.flash!.title, 'Họp thiết kế');
      say('sáu giờ chiều nay có họp không');
      expect(c.flash!.eyebrow, 'LÚC 18:00 · RẢNH');
      expect(c.flash!.title, 'Không có lịch');
      expect(c.flash!.meta, 'Sau đó cũng trống');
      expect(c.flash!.cool, isTrue);
      say('tám giờ sáng nay có họp không');
      expect(c.flash!.eyebrow, 'LÚC 08:00 · RẢNH');
      expect(c.flash!.meta, 'Tiếp theo 09:00 Họp đứng');
      expect(c.screen, Screen.home, reason: 'answered on the home screen');
    });
  });

  group('week and month (scenario 4)', () {
    test('week, free slots on Thursday, month and days until a deadline (also when STT gets a word wrong)', () async {
      await make();
      say('TUẦN NÀY ANH CÓ GÌ');
      expect(c.screen, Screen.week);
      say('THỨ NĂM RẢNH LÚC NÀO');
      expect(c.freeSlotsDay, DateTime(2026, 11, 19));
      say('MỞ LỊCH THÁNG NÀY');
      expect(c.screen, Screen.month);
      say('CÒN MẤY NGÀY TỚI HẠN GỬI BÁO CÁO');
      expect(c.countdownTo?.id, 'quote');
      say('CÒN MẤY NGÀY TỚI HẠN NỘP THUẾ');
      expect(c.flash!.eyebrow, 'KHÔNG THẤY');
      run(const Duration(seconds: 61));
      expect(c.screen, Screen.home, reason: 'idle return');
    });
  });

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

  group('VI/EN switch', () {
    Future<void> withEnglish() async {
      await make();
      voice.emit(const VoiceReady('m', stt: 'zipformer', wake: 'sherpa-kws', langs: ['vi', 'en']));
    }

    test('Vietnamese by default; English is offered only by a service that has it', () async {
      await make();
      expect((c.voiceLang, c.englishAvailable, c.listenLang), ('vi', false, 'vi'));
      voice.emit(const VoiceReady('m', langs: ['vi', 'en']));
      expect(c.englishAvailable, isTrue);
      voice.isReady = false;
      expect(c.englishAvailable, isFalse, reason: 'the service went away');
    });

    test('in English a listen asks for en and its words go through the English parser', () async {
      await withEnglish();
      c.toggleVoiceLang();
      expect((c.voiceLang, c.flash!.eyebrow), ('en', 'LỆNH TIẾNG ANH'));
      c.talk();
      expect((voice.sent.last, voice.listenLangs.last), ('listen l1', 'en'));
      expect(c.listening!.lang, 'en');
      voice.emit(const VoiceProcessing('l1'));
      voice.emit(const VoiceFinal('l1', 'Set a timer for 10 minutes.', engine: 'deepgram'));
      expect(c.timer!.duration, const Duration(minutes: 10));
    });

    test('English words not understood show English examples, Vietnamese ones are not read as English', () async {
      await withEnglish();
      c.toggleVoiceLang();
      say("It's a notch. Reveal the pool direct to me.");
      expect((c.listening!.phase, c.listening!.lang), (ListenPhase.notUnderstood, 'en'));
      c.cancelTalk();
      say('hẹn giờ 15 phút');
      expect(c.listening!.phase, ListenPhase.notUnderstood, reason: 'in English mode, Vietnamese is not parsed');
    });

    test('back to Vietnamese: listens ask for vi and the Vietnamese parser runs', () async {
      await withEnglish();
      c.toggleVoiceLang();
      c.toggleVoiceLang();
      expect((c.voiceLang, c.flash!.eyebrow), ('vi', 'LỆNH TIẾNG VIỆT'));
      say('hẹn giờ 15 phút');
      expect(voice.listenLangs.last, 'vi');
      expect(c.timer!.duration, const Duration(minutes: 15));
    });

    test('English chosen but gone from the service (no sign-in): listens fall back to Vietnamese', () async {
      await withEnglish();
      c.toggleVoiceLang();
      voice.emit(const VoiceReady('m', langs: ['vi']));
      expect((c.voiceLang, c.listenLang), ('en', 'vi'), reason: 'the choice is kept for when English is back');
      say('hẹn giờ 15 phút');
      expect(voice.listenLangs.last, 'vi');
      expect(c.timer!.duration, const Duration(minutes: 15));
    });

    test('a failed English listen (cloud down) says so in its own words', () async {
      await withEnglish();
      c.toggleVoiceLang();
      c.talk();
      voice.emit(const VoiceProcessing('l1'));
      voice.emit(const VoiceError('stt: HTTP 0'));
      expect((c.listening!.phase, c.listening!.lang), (ListenPhase.unavailable, 'en'));
    });

    test('the choice survives a restart', () async {
      await withEnglish();
      c.toggleVoiceLang();
      await store.idle;
      final again = AppController(clock: clock, store: LocalStore(store.file), calendar: FixedCalendar(events), voice: FakeVoice(), log: (_) {});
      await again.start(ticker: false);
      expect(again.voiceLang, 'en');
      again.dispose();
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

  group('morning brief (scenario 6)', () {
    test('shows by itself when the night ends, leaves after a minute, once a day', () async {
      await make(hour: 23, minute: 10);
      expect(c.screen, Screen.home);
      clock.set(DateTime(2026, 11, 17, 6, 29, 59));
      c.tick();
      expect(c.night, isTrue);
      expect(c.screen, Screen.home, reason: 'not during the night');
      run(const Duration(seconds: 1));
      expect(c.night, isFalse);
      expect(c.screen, Screen.brief, reason: 'the first awake tick after the night');
      run(const Duration(seconds: 59));
      expect(c.screen, Screen.brief);
      run(const Duration(seconds: 1));
      expect(c.screen, Screen.home, reason: 'idle return like the recap');
      run(const Duration(minutes: 5));
      expect(c.screen, Screen.home, reason: 'once a day');
    });

    test('awake before 06:00 ("bật màn"): it waits for 06:00', () async {
      await make(hour: 5, minute: 50);
      c.run(const ScreenOnCommand());
      expect(c.night, isFalse);
      run(const Duration(minutes: 9, seconds: 59));
      expect(c.screen, Screen.home);
      run(const Duration(seconds: 1));
      expect(c.screen, Screen.brief);
    });

    test('a first start in the morning shows it; a reboot the same day does not', () async {
      await make(hour: 8, minute: 25);
      expect(c.screen, Screen.brief);
      c.dismissBrief();
      expect(c.screen, Screen.home, reason: 'a tap goes home');
      await store.idle;
      await make(hour: 9, withStore: store);
      expect(c.screen, Screen.home, reason: 'already shown today');
    });

    test('not in the afternoon', () async {
      await make(hour: 14, minute: 0);
      expect(c.screen, Screen.home);
    });

    test('waits for a focus session and its alert, then shows', () async {
      await make(hour: 6, minute: 0);
      say('hẹn giờ 40 phút để tập trung');
      run(const Duration(minutes: 31));
      expect(c.night, isFalse);
      expect(c.screen, Screen.home, reason: 'not over a focus session');
      run(const Duration(minutes: 9));
      expect(c.alert, isA<TimerDoneAlert>());
      run(const Duration(seconds: 5));
      expect(c.screen, Screen.home, reason: 'not over an alert');
      c.alertAction(AlertAction.secondary);
      run(const Duration(seconds: 1));
      expect(c.screen, Screen.brief);
    });

    test('shows over the columns; swipes leave it for the columns', () async {
      await make(hour: 8, minute: 0);
      expect(c.layout.split, isTrue);
      expect(c.screen, Screen.brief);
      c.swipeUp();
      expect(c.screen, Screen.home);
      expect(c.layout.split, isTrue, reason: 'back to the columns');
    });

    test('carries yesterday\'s open notes and reminders, not the done ones, into the brief', () async {
      await make(hour: 14, minute: 0);
      say('ghi lại gửi báo giá cho khách trước thứ sáu');
      say('ghi lại đặt phòng họp thứ năm');
      c.toggleDone(c.notes.last.id);
      c.run(AddReminder('Gọi cho chị Lan', day.add(const Duration(hours: 15))));
      c.run(AddReminder('Mua quà sinh nhật mẹ', day.add(const Duration(hours: 16))));
      run(const Duration(hours: 1));
      expect((c.alert as ReminderAlert).reminder.text, 'Gọi cho chị Lan');
      c.alertAction(AlertAction.primary); // "Xong" for chị Lan
      run(const Duration(hours: 1));
      expect(c.alert, isA<ReminderAlert>());
      run(AppController.alertTimeout); // the gift reminder is left unanswered
      expect(c.morningBrief.carried, isEmpty, reason: 'nothing is carried on the same day');
      clock.set(DateTime(2026, 11, 17, 7, 59, 59));
      c.tick();
      say('ghi lại mua cà phê');
      expect(c.morningBrief.carried.map((i) => i.text), ['Gửi báo giá cho khách trước thứ sáu', 'Mua quà sinh nhật mẹ']);
    });
  });
}

/// The parser's ScreenOn command, under a name that reads well in a test.
typedef ScreenOnCommand = ScreenOn;
