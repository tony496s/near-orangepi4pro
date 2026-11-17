import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/clock.dart';
import '../domain/intent/vi_text.dart';
import '../voice/voice_client.dart';
import 'console_model.dart';
import 'console_script.dart';
import 'dev_words.dart';

enum VoicePhase { idle, listening, processing }

/// State of the agent console demo: the agents running in the box, their scripts, and the voice that gives them work.
///
/// Scripts advance on [tick] (every 200 ms from [start]). A lane stops on a card until [resolve] is called; a task
/// spoken after the wake word or a tap on the "giao việc" slot opens a new lane.
class AgentConsole extends ChangeNotifier {
  AgentConsole({required this.voice, this.clock = const SystemClock(), this.log = _noLog});

  final VoiceLink voice;
  final Clock clock;
  final void Function(String) log;

  static void _noLog(String _) {}

  /// Most lanes on the strip; a new task beyond that replaces the oldest finished lane.
  static const maxLanes = 5;

  /// Commands the box has let through without asking, shown on the rail (a believable start for a working day).
  static const startAutoApproved = 47;

  /// After the ship, the comparison screen comes up by itself this much later.
  static const whyAfterShip = Duration(seconds: 8);

  final lanes = <Lane>[];
  final flags = <String>{};
  int autoApproved = startAutoApproved;

  VoicePhase voicePhase = VoicePhase.idle;
  double level = -60;
  String lang = 'vi';
  List<String> langs = const ['vi'];

  /// A short line in the "giao việc" slot ("Không nghe rõ…"), until [_noteUntil].
  String? note;
  DateTime? _noteUntil;

  /// The comparison screen ("vì sao chỉ Near làm được") covers the strip.
  bool why = false;
  DateTime? _whyAt;

  /// Counts ticks: drives the blinking cursor and the spinner.
  int beat = 0;

  /// Plays the story by itself (nobody at the strip): gives the demo task, answers every card with the safe choice,
  /// ships, shows the comparison, then starts over.
  bool autoplay = false;
  DateTime _autoFrom = DateTime(0);

  static const autoTaskAfter = Duration(seconds: 6);
  static const autoAnswerAfter = Duration(seconds: 4);
  static const autoWhyFor = Duration(seconds: 12);
  static const autoTask = 'Thêm hiệu ứng chờ cho nút đăng nhập';

  /// Left alone this long, the strip goes back to the opening scene, so run times stay believable (a strip left on
  /// overnight would otherwise show agents running for hours, waiting on a human who never came).
  static const idleReset = Duration(minutes: 15);
  DateTime _touchedAt = DateTime(0);

  void _touch() => _touchedAt = clock.now();

  bool _mainTaken = false;
  int _listenSeq = 0;
  int _laneSeq = 0;
  String? _listenId;
  Timer? _ticker;
  StreamSubscription<VoiceEvent>? _sub;
  int _lastSecond = -1;

  bool get voiceReady => voice.ready;

  int get running => lanes.where((l) => l.state != LaneState.done).length;

  /// The MacBook is asleep: the presenter closed its lid and tapped it on the rail (the board cannot see the lid).
  bool macAsleep = false;

  /// The lane's machine is asleep, so its agent does not move on.
  bool isPaused(Lane l) => l.machine == Machine.macbook && macAsleep && l.state != LaneState.done;

  /// Agents on [m] that are not done.
  int agentsOn(Machine m) => lanes.where((l) => l.machine == m && l.state != LaneState.done).length;

  /// The build server has work: an agent runs on it, or a ship is at a stage that runs there.
  bool get serverBusy => lanes.any((l) {
        if (l.state == LaneState.done) return false;
        if (l.machine == Machine.server) return true;
        final card = l.card;
        return card is ShipCard && !card.done && card.placeOf(card.current) == Machine.server.name;
      });

  /// One word or two for the rail's machine list.
  String statusOf(Machine m) => switch (m) {
        Machine.box => 'luôn bật',
        Machine.macbook => macAsleep ? 'đã ngủ' : 'đang mở',
        Machine.server => serverBusy ? 'đang build' : 'rảnh',
      };

  void toggleMac() => setMacAsleep(!macAsleep);

  /// The MacBook goes to sleep or wakes. Asleep: its agents stop where they are, and each one that was simply working
  /// offers to move into the box ([HandoffCard]). Awake: they carry on.
  void setMacAsleep(bool asleep) {
    if (asleep == macAsleep) return;
    _touch();
    macAsleep = asleep;
    final now = clock.now();
    for (final l in lanes.where((l) => l.machine == Machine.macbook && l.state != LaneState.done)) {
      if (asleep) {
        l.addLog('MacBook đã ngủ, agent dừng tại đây');
        if (l.card != null) continue; // already waiting on the human: keeps its card, just does not move on
        l
          ..card = const HandoffCard(Machine.macbook)
          ..pending = ((choice) => choice == HandoffCard.move ? moveIntoBox() : const <Step>[])
          ..waitingSince = now
          ..state = LaneState.paused;
        voice.chime('soft');
      } else {
        l.addLog('MacBook thức, agent chạy tiếp');
        if (l.card is HandoffCard) {
          l
            ..card = null
            ..pending = null
            ..waitingSince = null;
        }
        if (l.state == LaneState.paused) l.state = LaneState.running;
        l.nextAt = null; // the next step is due its own delay from now, not from before the sleep
      }
    }
    notifyListeners();
  }

  /// RAM the agents would take on the box: ~340 MB per Claude Code process (measured on a Mac), plus the system.
  double get ramGb => .6 + .34 * agentsOn(Machine.box);

  void start({bool ticker = true}) {
    reset();
    _sub = voice.events.listen(_onVoice);
    if (voice.ready) voice.setWake(true);
    if (ticker) _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) => tick());
  }

  /// Back to the opening scene: three agents running, nothing waiting.
  void reset() {
    final now = clock.now();
    lanes
      ..clear()
      ..addAll(initialLanes(now));
    for (final l in lanes) {
      l.nextAt = now.add(l.steps.first.after);
    }
    flags.clear();
    autoApproved = startAutoApproved;
    if (voicePhase != VoicePhase.idle) voice.cancel();
    voicePhase = VoicePhase.idle;
    _listenId = null;
    note = null;
    why = false;
    _whyAt = null;
    _mainTaken = false;
    macAsleep = false;
    _autoFrom = now;
    _touchedAt = now;
    notifyListeners();
  }

  void setAutoplay(bool on) {
    _touch();
    autoplay = on;
    _autoFrom = clock.now();
    notifyListeners();
  }

  void _autoStep(DateTime now) {
    if (why) {
      if (!now.isBefore(_autoFrom.add(autoWhyFor))) reset();
      return;
    }
    if (!_mainTaken && voicePhase == VoicePhase.idle && !now.isBefore(_autoFrom.add(autoTaskAfter))) {
      addTask(autoTask, voiceGiven: true);
      return;
    }
    for (final l in [...lanes]) {
      final since = l.waitingSince;
      if (since == null || now.isBefore(since.add(autoAnswerAfter))) continue;
      switch (l.card) {
        case QuestionCard(:final recommended):
          resolve(l, recommended);
        case DangerCard():
          resolve(l, DangerCard.deny);
        case ReviewCard():
          resolve(l, ReviewCard.approve);
        case HandoffCard():
          resolve(l, HandoffCard.move);
        case ShipCard() || null:
          if (l.shippable) ship(l);
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  void tick() {
    final now = clock.now();
    beat++;
    var changed = false;
    for (final l in [...lanes]) {
      changed |= _advance(l, now);
    }
    if (_whyAt != null && !now.isBefore(_whyAt!)) {
      _whyAt = null;
      why = true;
      _autoFrom = now;
      changed = true;
    }
    if (autoplay) _autoStep(now);
    if (!autoplay && voicePhase == VoicePhase.idle && !now.isBefore(_touchedAt.add(idleReset))) {
      reset();
      return;
    }
    if (note != null && _noteUntil != null && now.isAfter(_noteUntil!)) {
      note = null;
      changed = true;
    }
    // Elapsed times and the blinking cursor.
    final second = now.millisecondsSinceEpoch ~/ 500;
    if (second != _lastSecond) {
      _lastSecond = second;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  bool _advance(Lane l, DateTime now) {
    if (isPaused(l)) return false;
    var changed = false;
    while (l.pending == null && l.cursor < l.steps.length) {
      final step = l.steps[l.cursor];
      if (step is Wait) {
        if (!flags.contains(step.flag)) {
          if (step.idle.isNotEmpty) {
            l.idleAt ??= now.add(step.every);
            if (!now.isBefore(l.idleAt!)) {
              l.addLog(step.idle[l.idleIndex++ % step.idle.length]);
              l.idleAt = now.add(step.every);
              changed = true;
            }
          }
          return changed;
        }
        l.idleAt = null;
        _next(l, now);
        continue;
      }
      final due = l.nextAt ??= now.add(step.after);
      if (now.isBefore(due)) return changed;
      _apply(l, step, now);
      _next(l, now);
      changed = true;
    }
    return changed;
  }

  void _next(Lane l, DateTime now) {
    l.cursor++;
    l.nextAt = l.cursor < l.steps.length ? now.add(l.steps[l.cursor].after) : null;
  }

  void _apply(Lane l, Step step, DateTime now) {
    switch (step) {
      case Say(:final text, :final command, :final progress):
        l.addLog(text);
        if (command) autoApproved++;
        if (progress != null) l.progress = progress;
      case Ask(:final card, :final next):
        l.card = card;
        l.pending = next;
        l.waitingSince = now;
        l.state = switch (card) {
          DangerCard() => LaneState.blocked,
          ReviewCard() => LaneState.review,
          _ => LaneState.asking,
        };
        voice.chime(card is DangerCard ? 'alert' : 'soft');
      case Raise(:final flag):
        flags.add(flag);
        if (flag == Flags.shipped) _whyAt = now.add(whyAfterShip);
      case ShipStage(:final index):
        l.state = LaneState.shipping;
        l.card = ShipCard(shipStages, index, version: shipVersion);
        if (index > 0) l.addLog('✓ ${shipStages[index - 1]}');
        if (index == shipStages.length) voice.chime('soft');
      case Finish(:final summary, :final shippable):
        l.card = null;
        l.summary = summary;
        l.shippable = shippable;
        l.state = shippable ? LaneState.ready : LaneState.done;
        l.progress = 1;
        l.finishedAt = now;
        l.waitingSince = shippable ? now : null;
      case MoveTo(:final machine):
        l.machine = machine;
      case Wait():
        break;
    }
  }

  /// The human picked [choice] on [lane]'s card.
  void resolve(Lane lane, int choice) {
    final next = lane.pending;
    if (next == null) return;
    _touch();
    final now = clock.now();
    final card = lane.card;
    if (card is QuestionCard && choice >= 0 && choice < card.options.length) lane.addLog('Anh chọn: ${card.options[choice]}');
    if (card is DangerCard) lane.addLog(choice == DangerCard.deny ? 'Anh từ chối lệnh' : 'Anh cho phép lệnh');
    lane
      ..pending = null
      ..card = null
      ..waitingSince = null
      ..state = LaneState.running;
    if (card is HandoffCard) {
      if (choice == HandoffCard.move) {
        lane.machine = Machine.box; // at once: the steps that follow must run while the MacBook sleeps
      } else {
        lane
          ..state = LaneState.paused
          ..addLog('Để agent chờ MacBook thức');
      }
    }
    final steps = next(choice);
    lane.steps.insertAll(lane.cursor, steps);
    lane.nextAt = steps.isEmpty ? null : now.add(steps.first.after);
    _advance(lane, now);
    notifyListeners();
  }

  /// Ships a lane that is ready for it (button or "ship bản test").
  void ship(Lane lane) {
    if (!lane.shippable) return;
    _touch();
    final now = clock.now();
    lane
      ..shippable = false
      ..waitingSince = null
      ..finishedAt = null
      ..summary = null
      ..state = LaneState.shipping
      ..progress = 0;
    lane.steps.addAll(shipScript());
    lane.nextAt = now.add(lane.steps[lane.cursor].after);
    _advance(lane, now);
    notifyListeners();
  }

  void showWhy(bool on) {
    _touch();
    why = on;
    _whyAt = null;
    _autoFrom = clock.now(); // autoplay keeps a screen opened by hand for its full time too
    notifyListeners();
  }

  void toggleLang() {
    if (!langs.contains('en')) return;
    _touch();
    lang = lang == 'vi' ? 'en' : 'vi';
    notifyListeners();
  }

  /// The mic: starts listening, or ends a listen so what was said gets transcribed.
  void talk() {
    _touch();
    switch (voicePhase) {
      case VoicePhase.listening:
        voice.finish();
        return;
      case VoicePhase.processing:
        return;
      case VoicePhase.idle:
        break;
    }
    if (!voice.ready) {
      _say('Mic chưa sẵn sàng, thử lại sau vài giây');
      return;
    }
    final id = 'a${++_listenSeq}';
    _listenId = id;
    voicePhase = VoicePhase.listening;
    level = -60;
    note = null;
    voice.listen(id, lang: lang);
    notifyListeners();
  }

  /// Drops the listen without acting on it.
  void cancelTalk() {
    if (voicePhase == VoicePhase.idle) return;
    voice.cancel();
    voicePhase = VoicePhase.idle;
    _listenId = null;
    notifyListeners();
  }

  void _onVoice(VoiceEvent ev) {
    switch (ev) {
      case VoiceReady(:final langs):
        this.langs = langs;
        if (!langs.contains(lang)) lang = langs.first;
        voice.setWake(true);
      case VoiceWake():
        if (voicePhase == VoicePhase.idle && !why) talk();
        return;
      case VoiceListening(:final id):
        if (id != _listenId) return;
        voicePhase = VoicePhase.listening;
      case VoiceLevel(:final db):
        if (voicePhase != VoicePhase.listening) return;
        level = db;
      case VoiceProcessing(:final id):
        if (id != _listenId) return;
        voicePhase = VoicePhase.processing;
      case VoiceFinal(:final id, :final text):
        if (id != _listenId) return;
        voicePhase = VoicePhase.idle;
        _listenId = null;
        log('heard: "$text"');
        heard(text);
        return;
      case VoiceTimeout(:final id):
        if (id != _listenId) return;
        voicePhase = VoicePhase.idle;
        _listenId = null;
        _say('Không nghe thấy gì, chạm để nói lại');
        return;
      case VoiceError(:final message):
        log('voice error: $message');
        if (voicePhase == VoicePhase.idle) return;
        voicePhase = VoicePhase.idle;
        _listenId = null;
        _say('Mic lỗi, chạm để thử lại');
        return;
      case VoiceDisconnected():
        if (voicePhase != VoicePhase.idle) {
          voicePhase = VoicePhase.idle;
          _listenId = null;
        }
    }
    notifyListeners();
  }

  /// What was said: "ship" ships the lane that is ready; anything else is a new task.
  void heard(String text) {
    final tokens = fixDevWords(tokenize(text));
    if (tokens.isEmpty) {
      _say('Không nghe rõ, chạm để nói lại');
      return;
    }
    if (isShipRequest(tokens)) {
      final ready = lanes.where((l) => l.shippable).toList();
      if (ready.isNotEmpty) {
        ship(ready.first);
      } else {
        _say('Chưa có bản nào sẵn sàng ship');
      }
      return;
    }
    addTask(sentence(tokens), voiceGiven: true);
  }

  /// Opens a lane for [task]. The first one after a reset runs the login story; later ones a short generic run.
  Lane? addTask(String task, {bool voiceGiven = false}) {
    _touch();
    if (lanes.length >= maxLanes) {
      final i = lanes.indexWhere((l) => l.state == LaneState.done);
      if (i < 0) {
        _say('Hộp đang chạy đủ $maxLanes agent');
        return null;
      }
      lanes.removeAt(i);
    }
    final now = clock.now();
    final main = !_mainTaken;
    _mainTaken = true;
    final lane = Lane(
      id: 'task-${++_laneSeq}',
      repo: main ? 'harness-mobile' : repoFor(tokenize(task)),
      engine: Engine.claude,
      task: task,
      startedAt: now,
      voiceGiven: voiceGiven,
      log: const ['Nhận việc từ giọng nói'],
      steps: main ? loginScript() : genericScript(),
    );
    lane.nextAt = now.add(lane.steps.first.after);
    lanes.add(lane);
    voice.chime('soft');
    notifyListeners();
    return lane;
  }

  void _say(String text, {Duration hold = const Duration(seconds: 4)}) {
    note = text;
    _noteUntil = clock.now().add(hold);
    notifyListeners();
  }
}

/// "ship bản test", "síp bản tét", "release", "lên testflight"…
bool isShipRequest(List<String> tokens) {
  const words = {'ship', 'síp', 'sip', 'shíp', 'syp', 'xíp', 'testflight', 'flight', 'release', 'deploy'};
  if (tokens.any(words.contains)) return true;
  if (hasPhrase(tokens, 'phát hành')) return true;
  final i = tokens.indexOf('bản');
  return i >= 0 && i + 1 < tokens.length && const {'test', 'tét', 'thử'}.contains(tokens[i + 1]);
}

/// Which repo a spoken task is about.
String repoFor(List<String> tokens) {
  if (tokens.any(const {'backend', 'server', 'api', 'sơ', 'vơ'}.contains)) return 'harness-backend';
  if (tokens.any(const {'docs', 'doc', 'readme'}.contains) || hasPhrase(tokens, 'tài liệu')) return 'harness-docs';
  if (tokens.contains('near')) return 'near-app';
  return 'harness-mobile';
}
