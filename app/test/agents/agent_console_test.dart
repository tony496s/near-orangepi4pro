import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/agents/agent_console.dart';
import 'package:near_app/agents/console_layout.dart';
import 'package:near_app/agents/console_model.dart';
import 'package:near_app/agents/console_script.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/domain/intent/vi_text.dart';
import 'package:near_app/voice/voice_client.dart';

import '../support/fakes.dart';

class Rig {
  Rig() {
    console = AgentConsole(voice: voice, clock: clock)..start(ticker: false);
  }

  final clock = FakeClock(DateTime(2026, 11, 18, 9));
  final voice = FakeVoice();
  late final AgentConsole console;

  /// Advances time in 200 ms ticks, like the app's ticker.
  void run(Duration d) {
    for (var t = 0; t < d.inMilliseconds; t += 200) {
      clock.advance(const Duration(milliseconds: 200));
      console.tick();
    }
  }

  void say(String text) {
    console.talk();
    final id = voice.sent.last.split(' ').last;
    voice.emit(VoiceFinal(id, text));
  }

  Lane lane(String id) => console.lanes.firstWhere((l) => l.id == id);

  Lane get task => console.lanes.firstWhere((l) => l.voiceGiven || l.id.startsWith('task-'));

  /// Runs until [lane] shows a card (at most [limit]).
  void until(bool Function() done, {Duration limit = const Duration(seconds: 60)}) {
    for (var t = 0; t < limit.inMilliseconds && !done(); t += 200) {
      run(const Duration(milliseconds: 200));
    }
    expect(done(), isTrue, reason: 'condition not met within $limit');
  }

  /// Plays the story up to the ship button: the spoken task's question, the denied push --force, the approved review.
  Lane storyToShip([String said = 'THÊM LOADING CHO NÚT ĐĂNG NHẬP']) {
    say(said);
    final task = console.lanes.last;
    until(() => task.card is QuestionCard);
    console.resolve(task, 0);
    final backend = lane('backend');
    until(() => backend.card is DangerCard);
    console.resolve(backend, DangerCard.deny);
    until(() => task.card is ReviewCard);
    console.resolve(task, ReviewCard.approve);
    until(() => task.state == LaneState.ready);
    return task;
  }
}

void main() {
  group('opening scene', () {
    test('three agents run in the box, nothing waits for the human', () {
      final r = Rig();
      expect(r.console.lanes.map((l) => l.repo), ['harness-backend', 'near-app', 'harness-web']);
      expect(r.console.lanes.every((l) => l.state == LaneState.running && l.card == null), isTrue);
      expect(r.console.running, 3);
      expect(r.console.autoApproved, AgentConsole.startAutoApproved);
      expect(r.lane('backend').elapsed(r.clock.now()), const Duration(minutes: 6, seconds: 12));
    });

    test('logs move on and commands count as let through', () {
      final r = Rig();
      final before = r.lane('backend').log.length;
      r.run(const Duration(seconds: 9));
      expect(r.lane('backend').log.length, greaterThan(before + 1));
      expect(r.lane('backend').log, contains(r'$ npm test -- auth   18/18 ✓'));
      expect(r.console.autoApproved, greaterThan(AgentConsole.startAutoApproved));
    });

    test('a lane waiting on another one keeps logging idle lines', () {
      final r = Rig();
      r.run(const Duration(seconds: 30));
      final backend = r.lane('backend');
      expect(backend.card, isNull);
      expect(backend.log.where((l) => l.contains('lint') || l.contains('token.ts') || l.contains('9/9')), isNotEmpty);
      expect(backend.log.length, lessThanOrEqualTo(Lane.maxLog));
    });
  });

  group('voice', () {
    test('a spoken task opens a lane with the sentence as its title', () {
      final r = Rig();
      r.console.talk();
      expect(r.voice.sent.last, 'listen a1');
      expect(r.console.voicePhase, VoicePhase.listening);
      r.voice.emit(const VoiceProcessing('a1'));
      expect(r.console.voicePhase, VoicePhase.processing);
      r.voice.emit(const VoiceFinal('a1', 'HEY NEAR THÊM LOADING CHO NÚT ĐĂNG NHẬP'));
      expect(r.console.voicePhase, VoicePhase.idle);
      expect(r.console.lanes, hasLength(4));
      final lane = r.console.lanes.last;
      expect(lane.task, 'Thêm loading cho nút đăng nhập');
      expect(lane.repo, 'harness-mobile');
      expect(lane.voiceGiven, isTrue);
      expect(r.voice.sent, contains('chime soft'));
    });

    test('a second tap while listening finishes the listen', () {
      final r = Rig();
      r.console.talk();
      r.console.talk();
      expect(r.voice.sent.last, 'finish');
    });

    test('nothing said, or nothing understood, leaves a note and no lane', () {
      final r = Rig();
      r.console.talk();
      r.voice.emit(const VoiceTimeout('a1'));
      expect(r.console.note, contains('Không nghe thấy'));
      expect(r.console.voicePhase, VoicePhase.idle);
      r.say('   ');
      expect(r.console.note, contains('Không nghe rõ'));
      expect(r.console.lanes, hasLength(3));
      r.run(const Duration(seconds: 5));
      expect(r.console.note, isNull);
    });

    test('mic not ready: a note instead of a listen', () {
      final r = Rig();
      r.voice.isReady = false;
      r.console.talk();
      expect(r.voice.sent.where((s) => s.startsWith('listen')), isEmpty);
      expect(r.console.note, contains('Mic chưa sẵn sàng'));
    });

    test('events of an old listen are ignored', () {
      final r = Rig();
      r.console.talk();
      r.voice.emit(const VoiceFinal('zz', 'THÊM NÚT'));
      expect(r.console.lanes, hasLength(3));
      expect(r.console.voicePhase, VoicePhase.listening);
    });

    test('the wake word listens; ready turns the wake word on and offers English', () {
      final r = Rig();
      r.voice.emit(const VoiceReady('m', langs: ['vi', 'en']));
      expect(r.voice.wakes.last, isTrue);
      expect(r.console.langs, ['vi', 'en']);
      r.console.toggleLang();
      expect(r.console.lang, 'en');
      r.voice.emit(const VoiceWake('hey near'));
      expect(r.voice.listenLangs.last, 'en');
      expect(r.console.voicePhase, VoicePhase.listening);
    });

    test('an error or a dropped service ends the listen', () {
      final r = Rig();
      r.console.talk();
      r.voice.emit(const VoiceError('mic gone'));
      expect(r.console.voicePhase, VoicePhase.idle);
      expect(r.console.note, contains('Mic lỗi'));
      r.console.talk();
      r.voice.emit(const VoiceDisconnected());
      expect(r.console.voicePhase, VoicePhase.idle);
    });

    test('long press cancel drops the listen', () {
      final r = Rig();
      r.console.talk();
      r.console.cancelTalk();
      expect(r.voice.sent.last, 'cancel');
      expect(r.console.voicePhase, VoicePhase.idle);
    });
  });

  group('the story', () {
    test('question, dangerous command, review, ship, then the comparison screen', () {
      final r = Rig();
      r.run(const Duration(seconds: 12));
      r.say('THÊM LOADING CHO NÚT ĐĂNG NHẬP');
      final task = r.console.lanes.last;

      r.until(() => task.card is QuestionCard);
      expect(task.state, LaneState.asking);
      expect(r.lane('backend').card, isNull, reason: 'the backend agent waits for the question to be answered');
      r.console.resolve(task, 0);
      expect(r.console.flags, contains(Flags.asked));
      expect(task.log, contains('Anh chọn: Trong nút'));

      final backend = r.lane('backend');
      r.until(() => backend.card is DangerCard);
      expect(backend.state, LaneState.blocked);
      expect(r.voice.sent, contains('chime alert'));
      r.run(const Duration(seconds: 15));
      expect(task.card, isNull, reason: 'the review waits until the dangerous command is decided');

      r.console.resolve(backend, DangerCard.deny);
      expect(backend.log.last, 'Anh từ chối lệnh');
      r.until(() => backend.state == LaneState.done);
      expect(backend.log, contains('Đã dừng, không push --force'));
      expect(backend.summary, 'PR #129 · chờ review');

      r.until(() => task.card is ReviewCard);
      expect(task.state, LaneState.review);
      r.console.resolve(task, ReviewCard.approve);
      r.until(() => task.state == LaneState.ready);
      expect(task.shippable, isTrue);
      expect(task.summary, 'PR #128 · CI ✓');

      r.console.ship(task);
      expect(task.state, LaneState.shipping);
      expect(task.card, isA<ShipCard>());
      r.until(() => task.state == LaneState.done);
      expect(task.summary, 'Bản $shipVersion đã lên TestFlight');
      expect(task.log, contains('✓ Build iOS · Server build'));
      expect(task.log, contains('✓ Apple xử lý'));
      expect(r.console.flags, contains(Flags.shipped));

      expect(r.console.why, isFalse);
      r.run(AgentConsole.whyAfterShip + const Duration(seconds: 1));
      expect(r.console.why, isTrue);
      r.console.showWhy(false);
      expect(r.console.why, isFalse);
    });

    test('allowing the dangerous command pushes it', () {
      final r = Rig();
      r.say('THÊM LOADING');
      final task = r.console.lanes.last;
      r.until(() => task.card is QuestionCard);
      r.console.resolve(task, 1);
      expect(task.log, contains('Anh chọn: Thay cả nút'));
      final backend = r.lane('backend');
      r.until(() => backend.card is DangerCard);
      r.console.resolve(backend, DangerCard.allow);
      r.until(() => backend.state == LaneState.done);
      expect(backend.summary, 'Đã push --force lên main');
    });

    test('redo runs another pass and asks again', () {
      final r = Rig();
      r.say('THÊM LOADING');
      final task = r.console.lanes.last;
      r.until(() => task.card is QuestionCard);
      r.console.resolve(task, 0);
      final backend = r.lane('backend');
      r.until(() => backend.card is DangerCard);
      r.console.resolve(backend, DangerCard.deny);
      r.until(() => task.card is ReviewCard);
      r.console.resolve(task, ReviewCard.redo);
      expect(task.card, isNull);
      r.until(() => task.card is ReviewCard);
      expect(task.log, contains('Làm lại: spinner nhỏ hơn, giữ chữ trên nút'));
    });

    test('"ship bản test" ships the lane that is ready, and only that', () {
      final r = Rig();
      r.say('SHIP BẢN TEST');
      expect(r.console.note, 'Chưa có bản nào sẵn sàng ship');
      expect(r.console.lanes, hasLength(3));

      final lane = r.console.addTask('Thêm loading')!;
      lane
        ..shippable = true
        ..state = LaneState.ready;
      r.say('SÍP BẢN TÉT');
      expect(lane.state, LaneState.shipping);
      expect(r.console.lanes, hasLength(4));
    });

    test('a resolve without a card does nothing', () {
      final r = Rig();
      final backend = r.lane('backend');
      final steps = backend.steps.length;
      r.console.resolve(backend, 0);
      expect(backend.steps.length, steps);
      r.console.ship(backend);
      expect(backend.state, LaneState.running);
    });

    test('later tasks run the short generic script, in the repo they name', () {
      final r = Rig();
      r.console.addTask('Thêm loading');
      final lane = r.console.addTask('Sửa api backend trả chậm')!;
      expect(lane.repo, 'harness-backend');
      r.until(() => lane.state == LaneState.done);
      expect(lane.summary, 'Xong · chờ review');
    });

    test('the box holds five lanes; a sixth replaces a finished one or is refused', () {
      final r = Rig();
      r.console.addTask('Một');
      final fifth = r.console.addTask('Hai')!;
      expect(r.console.lanes, hasLength(AgentConsole.maxLanes));
      expect(r.console.addTask('Ba'), isNull);
      expect(r.console.note, contains('đủ 5 agent'));
      r.until(() => fifth.state == LaneState.done);
      final sixth = r.console.addTask('Ba');
      expect(sixth, isNotNull);
      expect(r.console.lanes, hasLength(AgentConsole.maxLanes));
      expect(r.console.lanes, isNot(contains(fifth)));
    });

    test('reset goes back to the opening scene', () {
      final r = Rig();
      r.say('THÊM LOADING');
      final task = r.console.lanes.last;
      r.until(() => task.card is QuestionCard);
      r.console.resolve(task, 0);
      r.console.talk();
      r.console.showWhy(true);
      r.console.reset();
      expect(r.console.lanes, hasLength(3));
      expect(r.console.flags, isEmpty);
      expect(r.console.why, isFalse);
      expect(r.console.voicePhase, VoicePhase.idle);
      expect(r.voice.sent.last, 'cancel');
      // The login story is available again.
      expect(r.console.addTask('Thêm loading')!.repo, 'harness-mobile');
    });

    test('left alone for 15 minutes, the strip goes back to the opening scene', () {
      final r = Rig();
      r.say('THÊM HIỆU ỨNG CHỜ');
      r.run(AgentConsole.idleReset - const Duration(seconds: 1));
      expect(r.console.lanes, hasLength(4));
      r.run(const Duration(seconds: 2));
      expect(r.console.lanes, hasLength(3));
      expect(r.lane('backend').elapsed(r.clock.now()), lessThan(const Duration(minutes: 6, seconds: 15)));
    });

    test('a touch restarts the idle wait', () {
      final r = Rig();
      r.run(AgentConsole.idleReset - const Duration(minutes: 1));
      r.console.showWhy(true);
      r.console.showWhy(false);
      r.run(const Duration(minutes: 2));
      expect(r.console.lanes.first.elapsed(r.clock.now()), greaterThan(const Duration(minutes: 20)));
    });

    test('RAM grows with running agents', () {
      final r = Rig();
      final three = r.console.ramGb;
      r.console.addTask('Một');
      expect(r.console.ramGb, closeTo(three + .34, 1e-9));
    });
  });

  group('autoplay', () {
    test('plays the whole story by itself, then starts over', () {
      final r = Rig();
      final start = r.clock.now();
      r.console.setAutoplay(true);
      r.run(AgentConsole.autoSleepAfter - const Duration(milliseconds: 400));
      expect(r.console.macAsleep, isFalse);
      r.until(() => r.console.macAsleep);
      final web = r.lane('web');
      expect(web.card, isA<HandoffCard>());
      expect(web.state, LaneState.paused);
      r.until(() => web.machine == Machine.box);
      expect(web.card, isNull, reason: 'autoplay moves the MacBook agent into the box');
      r.until(() => r.console.lanes.length == 4);
      expect(r.clock.now().difference(start), greaterThanOrEqualTo(AgentConsole.autoTaskAfter));
      final task = r.console.lanes.last;
      expect(task.task, AgentConsole.autoTask);
      expect(task.voiceGiven, isTrue);
      r.until(() => task.card is QuestionCard);
      expect(web.log, contains('Tiếp tục trong hộp'));
      r.until(() => task.card == null);
      expect(task.log, contains('Anh chọn: Trong nút'));
      final backend = r.lane('backend');
      r.until(() => backend.card is DangerCard);
      r.until(() => backend.state == LaneState.done);
      expect(backend.summary, 'PR #129 · chờ review', reason: 'autoplay denies the dangerous command');
      r.until(() => task.state == LaneState.shipping, limit: const Duration(seconds: 90));
      r.until(() => r.console.why, limit: const Duration(seconds: 90));
      expect(web.summary, 'PR #130 · chờ review', reason: 'the moved agent finished in the box');
      r.until(() => !r.console.why);
      expect(r.console.lanes, hasLength(3));
      expect(r.console.macAsleep, isFalse, reason: 'starting over wakes the MacBook');
      expect(r.lane('web').machine, Machine.macbook);
      expect(r.console.autoplay, isTrue);
      r.until(() => r.console.macAsleep);
      r.until(() => r.console.lanes.length == 4);
    });

    test('the demo task waits while an agent still waits to move off the MacBook', () {
      final r = Rig();
      final start = r.clock.now();
      r.console.setAutoplay(true);
      r.until(() => r.console.macAsleep);
      r.console.toggleMac(); // woken by hand: the handoff is taken back
      r.run(start.add(AgentConsole.autoTaskAfter).difference(r.clock.now()) - const Duration(seconds: 1));
      expect(r.console.macAsleep, isFalse, reason: 'autoplay puts the MacBook to sleep once per run');
      r.console.toggleMac(); // asleep again just before the task is due: a fresh handoff
      final web = r.lane('web');
      r.run(const Duration(seconds: 2));
      expect(web.card, isA<HandoffCard>());
      expect(r.console.lanes, hasLength(3));
      r.until(() => r.console.lanes.length == 4);
      expect(web.machine, Machine.box);
      expect(web.card, isNull);
    });

    test('a comparison opened by hand stays its full time before autoplay starts over', () {
      final r = Rig();
      r.run(const Duration(seconds: 30));
      r.console.setAutoplay(true);
      r.console.showWhy(true);
      r.run(const Duration(seconds: 2));
      expect(r.console.why, isTrue);
      r.run(AgentConsole.autoWhyFor);
      expect(r.console.why, isFalse);
    });

    test('off: nothing is answered for the human', () {
      final r = Rig();
      r.run(const Duration(seconds: 20));
      expect(r.console.lanes, hasLength(3));
      r.say('THÊM HIỆU ỨNG CHỜ');
      final task = r.console.lanes.last;
      r.until(() => task.card is QuestionCard);
      r.run(const Duration(seconds: 30));
      expect(task.card, isA<QuestionCard>());
    });
  });

  group('machines', () {
    test('two agents run in the box and one on the MacBook, which is awake', () {
      final r = Rig();
      expect(r.console.lanes.map((l) => l.machine), [Machine.box, Machine.box, Machine.macbook]);
      expect(r.lane('web').machine, Machine.macbook);
      expect(r.console.macAsleep, isFalse);
      expect(r.console.agentsOn(Machine.box), 2);
      expect(r.console.agentsOn(Machine.macbook), 1);
      expect(r.console.agentsOn(Machine.server), 0);
      expect(r.console.statusOf(Machine.box), 'luôn bật');
      expect(r.console.statusOf(Machine.macbook), 'đang mở');
      expect(r.console.statusOf(Machine.server), 'rảnh');
      expect(r.console.serverBusy, isFalse);
      expect(r.console.lanes.any(r.console.isPaused), isFalse);
    });

    test('the MacBook going to sleep pauses its agent, which offers to move into the box', () {
      final r = Rig();
      r.run(const Duration(seconds: 2));
      expect(r.voice.sent, isNot(contains('chime soft')));
      r.console.toggleMac();
      expect(r.console.macAsleep, isTrue);
      expect(r.console.statusOf(Machine.macbook), 'đã ngủ');
      final web = r.lane('web');
      expect(web.state, LaneState.paused);
      expect(r.console.isPaused(web), isTrue);
      expect(web.card, isA<HandoffCard>().having((c) => c.from, 'from', Machine.macbook));
      expect(web.waitingSince, r.clock.now());
      expect(web.log.last, 'MacBook đã ngủ, agent dừng tại đây');
      expect(r.voice.sent, contains('chime soft'));
      for (final id in ['backend', 'near-app']) {
        expect(r.lane(id).state, LaneState.running, reason: id);
        expect(r.lane(id).card, isNull, reason: id);
        expect(r.console.isPaused(r.lane(id)), isFalse, reason: id);
      }
    });

    test('moved into the box, the agent takes its branch along and carries on to its PR', () {
      final r = Rig();
      r.console.toggleMac();
      final web = r.lane('web');
      final ram = r.console.ramGb;
      r.console.resolve(web, HandoffCard.move);
      expect(web.machine, Machine.box);
      expect(web.state, LaneState.running);
      expect(web.card, isNull);
      expect(r.console.isPaused(web), isFalse);
      expect(r.console.agentsOn(Machine.box), 3);
      expect(r.console.agentsOn(Machine.macbook), 0);
      expect(r.console.ramGb, closeTo(ram + .34, 1e-9));
      r.run(const Duration(seconds: 5));
      expect(
        web.log,
        containsAllInOrder(
            ['Chuyển vào hộp qua Harness', 'Nhận nhánh và phiên làm việc', r'$ git switch fix/upload-anh', 'Tiếp tục trong hộp']),
      );
      expect(r.console.macAsleep, isTrue, reason: 'it runs on while the MacBook sleeps');
      r.storyToShip();
      expect(r.console.flags, contains(Flags.approved));
      r.until(() => web.state == LaneState.done);
      expect(web.summary, 'PR #130 · chờ review');
      expect(web.machine, Machine.box);
    });

    test('left on the MacBook, a paused agent does not move on until the Mac wakes', () {
      final r = Rig();
      r.console.toggleMac();
      final web = r.lane('web');
      r.console.resolve(web, HandoffCard.stay);
      expect(web.card, isNull);
      expect(web.state, LaneState.paused);
      expect(web.machine, Machine.macbook);
      expect(web.log.last, 'Để agent chờ MacBook thức');
      final log = web.log.length;
      final cursor = web.cursor;
      final backendLog = r.lane('backend').log.length;
      r.run(const Duration(seconds: 30));
      expect(web.log.length, log, reason: 'a paused agent does not move on');
      expect(web.cursor, cursor);
      expect(r.lane('backend').log.length, greaterThan(backendLog));
      r.console.toggleMac();
      expect(web.state, LaneState.running);
      expect(web.log.last, 'MacBook thức, agent chạy tiếp');
      r.run(const Duration(seconds: 10));
      expect(web.log.length, greaterThan(log + 2));
      expect(web.log, isNot(contains('Tiếp tục trong hộp')));
    });

    test('a MacBook agent already waiting on a card keeps it when the Mac sleeps', () {
      final r = Rig();
      r.say('THÊM HIỆU ỨNG CHỜ CHO NÚT ĐĂNG NHẬP TRÊN LAPTOP');
      final task = r.task;
      expect(task.machine, Machine.macbook);
      r.until(() => task.card is QuestionCard);
      r.console.toggleMac();
      expect(task.card, isA<QuestionCard>());
      expect(task.state, LaneState.asking);
      expect(task.log.last, 'MacBook đã ngủ, agent dừng tại đây');
      expect(r.lane('web').card, isA<HandoffCard>());
    });

    test('answered while the Mac sleeps, the agent offers the move, then goes on in the box', () {
      final r = Rig();
      r.say('THÊM HIỆU ỨNG CHỜ CHO NÚT ĐĂNG NHẬP TRÊN LAPTOP');
      final task = r.task;
      r.until(() => task.card is QuestionCard);
      r.console.toggleMac();
      r.console.resolve(task, 0);
      expect(task.log, contains('Anh chọn: Trong nút'));
      expect(task.card, isA<HandoffCard>());
      expect(task.state, LaneState.paused);
      r.run(const Duration(seconds: 5));
      expect(r.console.flags, isNot(contains(Flags.asked)), reason: 'nothing runs on the sleeping MacBook');
      r.console.resolve(task, HandoffCard.move);
      expect(task.machine, Machine.box);
      r.until(() => r.console.flags.contains(Flags.asked));
      expect(task.log, containsAllInOrder(['Chuyển vào hộp qua Harness', r'$ git switch feat/login-loading', 'Tiếp tục trong hộp']));
    });

    test('waking the MacBook takes back an unanswered handoff', () {
      final r = Rig();
      r.console.toggleMac();
      final web = r.lane('web');
      expect(web.card, isA<HandoffCard>());
      r.console.toggleMac();
      expect(r.console.macAsleep, isFalse);
      expect(r.console.statusOf(Machine.macbook), 'đang mở');
      expect(web.card, isNull);
      expect(web.pending, isNull);
      expect(web.waitingSince, isNull);
      expect(web.state, LaneState.running);
      r.console.resolve(web, HandoffCard.move);
      expect(web.machine, Machine.macbook, reason: 'nothing is left to answer');
      final log = web.log.length;
      r.run(const Duration(seconds: 8));
      expect(web.log.length, greaterThan(log));
    });

    test('a finished MacBook agent ships while the Mac sleeps: the box runs the ship', () {
      final r = Rig();
      final task = r.storyToShip('THÊM LOADING CHO NÚT ĐĂNG NHẬP TRÊN MACBOOK');
      expect(task.machine, Machine.macbook);
      r.console.toggleMac();
      expect(task.card, isNull);
      expect(task.state, LaneState.ready);
      expect(r.console.isPaused(task), isFalse);
      r.console.ship(task);
      r.until(() => task.state == LaneState.done);
      expect(task.summary, 'Bản $shipVersion đã lên TestFlight');
    });

    test('RAM counts the agents in the box only', () {
      final r = Rig();
      final start = r.console.ramGb;
      expect(start, closeTo(.6 + .34 * 2, 1e-9));
      r.say('THÊM HIỆU ỨNG CHỜ TRÊN LAPTOP');
      expect(r.console.ramGb, closeTo(start, 1e-9));
      r.say('THÊM NÚT ĐĂNG XUẤT');
      expect(r.console.ramGb, closeTo(start + .34, 1e-9));
      r.console.toggleMac();
      r.console.resolve(r.lane('web'), HandoffCard.move);
      expect(r.console.ramGb, closeTo(start + .68, 1e-9));
    });

    test('reset wakes the MacBook and puts the web agent back on it', () {
      final r = Rig();
      r.console.toggleMac();
      r.console.resolve(r.lane('web'), HandoffCard.move);
      r.console.reset();
      expect(r.console.macAsleep, isFalse);
      final web = r.lane('web');
      expect(web.machine, Machine.macbook);
      expect(web.state, LaneState.running);
      expect(web.card, isNull);
      expect(r.console.isPaused(web), isFalse);
    });
  });

  group('ship on the build server', () {
    test('the box hands build, signing and upload to the server, busy until Apple has the build', () {
      final r = Rig();
      final task = r.storyToShip();
      expect(r.console.serverBusy, isFalse);
      r.console.ship(task);
      expect(task.log, containsAllInOrder(['Board ARM không build được iOS', '→ Giao Server build']));
      final card = task.card as ShipCard;
      expect(card.places, shipPlaces);
      expect(card.placeOf(card.current), Machine.server.name);
      expect(r.console.statusOf(Machine.server), 'đang build');
      final busy = <int, Set<bool>>{};
      r.until(() {
        final c = task.card;
        if (c is ShipCard) (busy[c.current] ??= {}).add(r.console.serverBusy);
        return task.state == LaneState.done;
      });
      expect(busy, {
        0: {true},
        1: {true},
        2: {true},
        3: {false},
        4: {false},
      });
      expect(r.console.serverBusy, isFalse);
      expect(r.console.statusOf(Machine.server), 'rảnh');
      expect(
        task.log,
        containsAllInOrder(['✓ Build iOS · Server build', '✓ Ký app · Server build', '✓ Upload · Server build', '✓ Apple xử lý']),
      );
    });
  });

  group('machine by voice', () {
    const title = 'Thêm hiệu ứng chờ cho nút đăng nhập';

    test('a task named for the MacBook runs there, said any way the board heard it', () {
      for (final said in ['TRÊN MA QUỐC', 'TRÊN MACBOOK', 'TRÊN LAPTOP', 'TRÊN MÁY MÓC']) {
        final r = Rig();
        r.say('THÊM HIỆU ỨNG CHỜ CHO NÚT ĐĂNG NHẬP $said');
        final task = r.task;
        expect(task.task, title, reason: said);
        expect(task.machine, Machine.macbook, reason: said);
        expect(task.repo, 'harness-mobile', reason: said);
        expect(task.log, contains('→ Giao MacBook qua Harness'), reason: said);
        expect(r.console.agentsOn(Machine.macbook), 2, reason: said);
        r.until(() => task.card is QuestionCard); // the login story, on the MacBook
      }
    });

    test('a task named for the server runs there, and the server is not taken for the backend repo', () {
      for (final said in ['TRÊN SERVER', 'TRÊN MÁI CHỦ', 'Ở MÁY CHỦ', 'TRÊN SƠ VƠ']) {
        final r = Rig();
        r.say('THÊM HIỆU ỨNG CHỜ CHO NÚT ĐĂNG NHẬP $said');
        expect(r.task.task, title, reason: said);
        expect(r.task.machine, Machine.server, reason: said);
        expect(r.task.log, contains('→ Giao Server build qua Harness'), reason: said);
        expect(r.console.serverBusy, isTrue, reason: said);
        expect(r.console.statusOf(Machine.server), 'đang build', reason: said);
        r.say('SỬA LỖI ĐĂNG XUẤT $said');
        final later = r.console.lanes.last;
        expect(later.task, 'Sửa lỗi đăng xuất', reason: said);
        expect(later.machine, Machine.server, reason: said);
        expect(later.repo, 'harness-mobile', reason: said);
      }
    });

    test('a task for the sleeping MacBook runs in the box, and the slot says so', () {
      final r = Rig();
      r.console.toggleMac();
      r.say('THÊM HIỆU ỨNG CHỜ CHO NÚT ĐĂNG NHẬP TRÊN MA QUỐC');
      final task = r.task;
      expect(task.task, title);
      expect(task.machine, Machine.box);
      expect(task.log, contains('MacBook đang ngủ → chạy trong hộp'));
      expect(r.console.note, 'MacBook đang ngủ → chạy trong hộp');
      expect(r.console.isPaused(task), isFalse);
      r.until(() => task.card is QuestionCard);
    });

    test('no machine named: the box', () {
      final r = Rig();
      r.say('THÊM HIỆU ỨNG CHỜ CHO NÚT ĐĂNG NHẬP');
      expect(r.task.machine, Machine.box);
      expect(r.task.log, ['Nhận việc từ giọng nói']);
      expect(r.console.agentsOn(Machine.box), 3);
    });

    test('a machine and nothing else is not a task', () {
      final r = Rig();
      r.say('TRÊN LAPTOP');
      expect(r.console.lanes, hasLength(3));
      expect(r.console.note, contains('Không nghe rõ'));
    });

    test('a new agent on the MacBook pauses too when the Mac falls asleep', () {
      final r = Rig();
      r.say('SỬA LỖI ĐĂNG XUẤT TRÊN LAPTOP');
      final task = r.task;
      r.run(const Duration(seconds: 1));
      expect(task.card, isNull);
      r.console.toggleMac();
      expect(task.card, isA<HandoffCard>());
      expect(task.state, LaneState.paused);
      expect(r.console.isPaused(task), isTrue);
    });
  });

  group('intent', () {
    test('misheard dev words are fixed in the lane title', () {
      final r = Rig();
      r.say('HAI NIA THÊM LEO ĐÌNH CHO NÚT ĐĂNG NHẬP');
      expect(r.console.lanes.last.task, 'Thêm loading cho nút đăng nhập');
    });

    test('ship requests', () {
      for (final s in ['ship bản test', 'SÍP BẢN TÉT', 'syp', 'lên testflight', 'phát hành bản mới', 'release đi', 'bản thử']) {
        expect(isShipRequest(tokenize(s)), isTrue, reason: s);
      }
      for (final s in ['thêm loading cho nút', 'sửa bản đồ', 'test lại login']) {
        expect(isShipRequest(tokenize(s)), isFalse, reason: s);
      }
    });

    test('repo from the sentence', () {
      expect(repoFor(tokenize('sửa api backend')), 'harness-backend');
      expect(repoFor(tokenize('cập nhật tài liệu cài đặt')), 'harness-docs');
      expect(repoFor(tokenize('near thêm cột')), 'near-app');
      expect(repoFor(tokenize('thêm nút đăng xuất')), 'harness-mobile');
    });
  });

  group('lane widths', () {
    const total = 1000.0;

    test('lanes without a card share equally', () {
      expect(laneWidths([null, null, null, null], total), [250, 250, 250, 250]);
      expect(laneWidths([], total), isEmpty);
    });

    test('a card lane gets what it asks for, the rest share what is left', () {
      final w = laneWidths([null, const QuestionCard('q', ['a']), null], total);
      expect(w[1], 560);
      expect(w[0], 220);
      expect(w.reduce((a, b) => a + b), closeTo(total, 1e-9));
    });

    test('the card gives way so no lane drops under the minimum', () {
      final w = laneWidths([null, null, null, null, const ReviewCard(tests: '', diff: '', files: 0, took: '')], total);
      expect(w.take(4), everyElement(laneMinWidth));
      expect(w.reduce((a, b) => a + b), closeTo(total, 1e-9));
    });

    test('only card lanes: scaled to fill', () {
      final w = laneWidths(const [DangerCard('x', 'y'), ShipCard(['a'], 0, version: '1')], 590);
      expect(w.reduce((a, b) => a + b), closeTo(590, 1e-9));
      expect(w[0], greaterThan(w[1]));
    });
  });
}
