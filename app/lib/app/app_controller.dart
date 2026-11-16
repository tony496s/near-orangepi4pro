import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/clock.dart';
import '../core/vi_format.dart';
import '../data/calendar_source.dart';
import '../data/fx_source.dart';
import '../data/local_store.dart';
import '../data/price_source.dart';
import '../domain/day_plan.dart';
import '../domain/intent/commands.dart';
import '../domain/intent/en_parser.dart';
import '../domain/intent/parser.dart';
import '../domain/models.dart';
import '../domain/gold_alert.dart';
import '../domain/strip_layout.dart';
import '../domain/timer_fit.dart';
import '../voice/voice_client.dart';
import 'scheduler.dart';

/// Base screens. `home` shows the day strip, or the focus screen while a focus session runs.
enum Screen { home, recap, tomorrow, gold, week, month, day }

/// A short confirmation or answer shown in the strip's right-hand block (or as a card during focus).
class Flash {
  const Flash({required this.eyebrow, required this.title, this.meta = '', this.cool = false, required this.until});

  final String eyebrow;
  final String title;
  final String meta;

  /// Cool (teal) for things the user just did; warm otherwise.
  final bool cool;
  final DateTime until;
}

enum ListenPhase { listening, thinking, heard, notUnderstood, noSpeech, unavailable }

class Listening {
  const Listening(this.phase, {this.id = '', this.text = '', this.level = -60, this.until, this.lang = 'vi'});

  final ListenPhase phase;
  final String id;

  /// The language this listen was in: "vi" or "en" (the VI/EN switch).
  final String lang;

  /// What was heard (heard, notUnderstood).
  final String text;
  final double level;

  /// When an informational phase (notUnderstood, noSpeech, unavailable) closes by itself.
  final DateTime? until;

  Listening copyWith({ListenPhase? phase, String? text, double? level, DateTime? until}) => Listening(phase ?? this.phase,
      id: id, text: text ?? this.text, level: level ?? this.level, until: until, lang: lang);
}

/// Full-screen notices that wait for a tap.
sealed class Alert {
  const Alert(this.shownAt);
  final DateTime shownAt;
}

final class TimerDoneAlert extends Alert {
  const TimerDoneAlert(this.timer, this.sessionNumber, super.shownAt);
  final ActiveTimer timer;

  /// 1-based focus session number today; 0 for a plain timer.
  final int sessionNumber;
}

final class ReminderAlert extends Alert {
  const ReminderAlert(this.reminder, super.shownAt);
  final Reminder reminder;
}

/// The gold price crossed the threshold the user asked about (once per alert).
final class GoldCrossedAlert extends Alert {
  const GoldCrossedAlert(this.rule, this.price, super.shownAt);
  final GoldAlert rule;
  final double price;
}

/// The two buttons of an alert: left (primary) and right.
enum AlertAction { primary, secondary }

/// A reminder that was said without a time; the strip asks "when?".
class AskTime {
  const AskTime(this.text);
  final String text;
}

/// Owns the strip's state: what is on screen, timers, notes, reminders, night mode, and the voice round trip.
/// Time comes from [clock]; [tick] runs once a second in the app and is called directly by tests.
class AppController extends ChangeNotifier {
  AppController({
    required this.clock,
    required this.store,
    required this.calendar,
    this.voice,
    this.settings = const ScheduleSettings(),
    this.prices = const SamplePriceSource(),
    this.fxRates = const SampleFxSource(),
    this.heardHold = const Duration(milliseconds: 700),
    this.log = _print,
  }) : _lastInteraction = clock.now();

  final Clock clock;
  final LocalStore store;
  final CalendarSource calendar;
  final VoiceLink? voice;
  final ScheduleSettings settings;
  final PriceSource prices;
  final FxSource fxRates;

  /// How long the heard sentence stays on screen before the command runs.
  final Duration heardHold;
  final void Function(String) log;

  static void _print(String s) => debugPrint(s);

  static const flashFor = Duration(seconds: 6);
  static const idleReturn = Duration(seconds: 60);
  static const peekFor = Duration(seconds: 10);
  static const alertTimeout = Duration(minutes: 10);
  static const retrySaveAfter = Duration(seconds: 30);
  static const finishTimeout = Duration(seconds: 10);

  StoredState _state = StoredState();
  DayPlan plan = DayPlan(const []);
  Screen screen = Screen.home;
  Flash? flash;
  Listening? listening;
  AskTime? askTime;
  final List<Alert> _alerts = [];
  DateTime? _manualNightUntil;
  DateTime? _nightSuppressedUntil;
  DateTime? peekUntil;
  String? soonEventId;
  DateTime? _soonUntil;
  final Set<String> _announced = {};
  DateTime _lastInteraction;
  int _listenSeq = 0;
  DateTime? _saveFailedAt;
  DateTime? _fetchedDay;
  Timer? _ticker;
  Timer? _heardTimer;
  StreamSubscription<VoiceEvent>? _voiceSub;
  bool _disposed = false;

  /// What the service was last told about the wake word; null until told on this connection.
  bool? _wakeSent;

  /// Languages the voice service offers (its last "ready"), the default first.
  List<String> _voiceLangs = const ['vi'];

  // ---------------------------------------------------------------- state for the UI

  DateTime get now => clock.now();
  bool get clockValid => clockLooksValid(now);
  ActiveTimer? get timer => _state.timer;
  List<Note> get notes => List.unmodifiable(_state.notes);
  List<Reminder> get reminders => List.unmodifiable(_state.reminders);
  List<FocusSession> get sessions => List.unmodifiable(_state.sessions);
  Alert? get alert => _alerts.isEmpty ? null : _alerts.first;
  bool get micReady => voice?.ready ?? false;
  bool get saveFailing => _saveFailedAt != null;

  bool get focusing {
    final t = _state.timer;
    return t != null && t.focus && !t.isDone(now);
  }

  bool get manualNight => _manualNightUntil != null;

  bool get night {
    if (!clockValid) return false;
    if (_manualNightUntil != null) return true;
    return isNightTime(now, settings) && _nightSuppressedUntil == null;
  }

  bool get peeking => peekUntil != null && now.isBefore(peekUntil!);

  /// Whether "Hey Near" should start a listen: not at night (the room may be asleep) and not during a focus session
  /// (a false wake there costs the most). The mic button works either way.
  bool get wakeWanted => !night && !focusing;

  /// The VI/EN switch, as saved. English goes through the cloud (Harness, Deepgram); Vietnamese stays on the board.
  String get voiceLang => _state.voiceLang;

  /// Home screen: three columns (first start) or the day strip, as last chosen.
  StripLayout get layout => _state.layout;

  /// Today's gold so far (sample data in the demo). Recomputed at most every few seconds.
  PriceSeries get gold {
    final t = now;
    final key = t.millisecondsSinceEpoch ~/ 5000;
    if (_goldKey != key || _gold == null) {
      _gold = prices.goldToday(t);
      _goldKey = key;
    }
    return _gold!;
  }

  PriceSeries? _gold;
  int? _goldKey;

  /// USD/VND sell rate, the last 31 days to today (sample data in the demo). The same all day, so read once a day.
  PriceSeries get fx {
    final d = dayOf(now);
    if (_fxDay != d || _fx == null) {
      _fx = fxRates.usdVnd(now);
      _fxDay = d;
    }
    return _fx!;
  }

  PriceSeries? _fx;
  DateTime? _fxDay;

  /// Yesterday's whole day, for the comparison line.
  PriceSeries get goldYesterday => prices.goldDay(now.subtract(const Duration(days: 1)));

  /// The gold chart shows yesterday's line too ("so với hôm qua").
  bool goldCompare = false;

  /// The price alert, if one is set (fired or not).
  GoldAlert? get goldAlert => _state.goldAlert;

  /// The day strip shows a small gold tile once the chart was opened today, or while a price alert is armed (scenario
  /// 3: "không xem nữa thì chart thu về một góc"). Not on the columns, which have a gold column of their own.
  bool get goldMini {
    if (layout.split) return false;
    final a = goldAlert;
    if (a != null && a.firedAt == null) return true;
    final seen = _goldSeen;
    return seen != null && sameDay(seen, now);
  }

  DateTime? _goldSeen;

  /// A plain timer that ended while the columns are home shows in its own column, not over the whole strip (scenario
  /// 5: "hết giờ thì báo ngay trong cột của nó"). Its buttons are [alertText]'s and go to [alertAction] as usual. A
  /// focus session ran on the whole strip, so its end does too (scenario 1: "Nghỉ 5 phút").
  TimerDoneAlert? get timerDoneInColumn {
    final a = alert;
    return a is TimerDoneAlert && !a.timer.focus && layout.split && screen == Screen.home ? a : null;
  }

  /// The day the week view highlights with its free slots ("thứ năm rảnh lúc nào"); null: none.
  DateTime? freeSlotsDay;

  /// The day opened from the week view (Screen.day).
  DateTime? openDay;

  /// The deadline asked about ("còn mấy ngày tới hạn …"), shown on the month view.
  CalendarEvent? countdownTo;

  /// The service can take English right now (it has a Harness sign-in); the switch is only shown then.
  bool get englishAvailable => (voice?.ready ?? false) && _voiceLangs.contains('en');

  /// What the next listen asks for: English only when chosen and available, else Vietnamese.
  String get listenLang => voiceLang == 'en' && englishAvailable ? 'en' : 'vi';

  /// Focus sessions completed today.
  List<FocusSession> get sessionsToday => _state.sessions.where((s) => s.completed && sameDay(s.end, now)).toList();

  // ---------------------------------------------------------------- lifecycle

  Future<void> start({bool ticker = true}) async {
    _state = await store.load();
    _state.prune(now);
    await refreshCalendar();
    _voiceSub = voice?.events.listen(_onVoice);
    if (ticker) _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    tick();
  }

  Future<void> refreshCalendar() async {
    final day = dayOf(now);
    try {
      // The week view starts on Monday and the month view shows the whole month, so fetch from the earlier of the
      // two up to the later of next month and a week ahead.
      final monday = DayPlan.weekOf(day).first;
      final monthStart = DateTime(day.year, day.month);
      final from = monday.isBefore(monthStart) ? monday : monthStart;
      final nextMonth = DateTime(day.year, day.month + 1);
      final weekAhead = day.add(const Duration(days: 8));
      final to = nextMonth.isAfter(weekAhead) ? nextMonth : weekAhead;
      plan = DayPlan(await calendar.fetch(from.isBefore(day) ? from : day.subtract(const Duration(days: 1)), to));
      _fetchedDay = day;
    } catch (e) {
      log('calendar fetch failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _heardTimer?.cancel();
    _voiceSub?.cancel();
    super.dispose();
  }

  void _notify() {
    if (_disposed) return;
    _syncWake();
    notifyListeners();
  }

  /// Tells the service when [wakeWanted] changes, and once after each (re)connection.
  void _syncWake() {
    final v = voice;
    if (v == null || !v.ready) return;
    final want = wakeWanted;
    if (_wakeSent == want) return;
    _wakeSent = want;
    log('wake: ${want ? 'on' : 'off'}');
    v.setWake(want);
  }

  // ---------------------------------------------------------------- once a second

  void tick() {
    final t = now;
    if (flash != null && !t.isBefore(flash!.until)) flash = null;
    if (peekUntil != null && !t.isBefore(peekUntil!)) peekUntil = null;
    if (_soonUntil != null && !t.isBefore(_soonUntil!)) {
      soonEventId = null;
      _soonUntil = null;
    }
    if (_manualNightUntil != null && !t.isBefore(_manualNightUntil!)) _manualNightUntil = null;
    if (_nightSuppressedUntil != null && !t.isBefore(_nightSuppressedUntil!)) _nightSuppressedUntil = null;
    final l = listening;
    if (l != null && l.until != null && !t.isBefore(l.until!)) listening = null;
    if (screen != Screen.home && t.difference(_lastInteraction) >= idleReturn) screen = Screen.home;
    _alerts.removeWhere((a) => t.difference(a.shownAt) >= alertTimeout);
    _expireAskFit(t);
    if (_saveFailedAt != null && t.difference(_saveFailedAt!) >= retrySaveAfter) _save();
    if (_fetchedDay != null && !sameDay(_fetchedDay!, t)) {
      _fetchedDay = dayOf(t);
      _announced.clear();
      unawaited(refreshCalendar().then((_) => _notify()));
    }

    final signals = checkSchedule(
      now: t,
      timer: _state.timer,
      reminders: _state.reminders,
      plan: plan,
      announced: _announced,
      lastRecapDay: _state.lastRecapDay,
      todayKey: dayKey(t),
      settings: settings,
    );
    for (final s in signals) {
      _handle(s, t);
    }
    _checkGold(t);
    _notify();
  }

  /// An event ahead whose title contains [query]; failing that, the one sharing the most words with it (at least two),
  /// since STT often gets one word wrong ("gửi báo cáo" for "gửi báo giá").
  CalendarEvent? _findAhead(String query, DateTime t) {
    final exact = plan.findAhead(query, t);
    if (exact != null) return exact;
    final words = query.toLowerCase().split(' ').toSet();
    CalendarEvent? best;
    var score = 1;
    for (final e in plan.events) {
      if (e.start.isBefore(dayOf(t))) continue;
      final s = e.title.toLowerCase().split(' ').where(words.contains).length;
      if (s > score) {
        best = e;
        score = s;
      }
    }
    return best;
  }

  void _checkGold(DateTime t) {
    final rule = _state.goldAlert;
    if (rule == null || rule.fired) return;
    final price = gold.last;
    if (!rule.crossedBy(price)) return;
    _state.goldAlert = rule.fire(t);
    _alerts.add(GoldCrossedAlert(rule, price, t));
    voice?.chime('alert');
    _save();
  }

  void _handle(Signal s, DateTime t) {
    switch (s) {
      case TimerFinished(:final timer):
        _state.timer = null;
        var n = 0;
        if (timer.focus) {
          _state.sessions.add(FocusSession(start: timer.startedAt, end: timer.endsAt, completed: true));
          n = sessionsToday.length;
        }
        _alerts.add(TimerDoneAlert(timer, n, t));
        voice?.chime('alert');
        _save();
      case ReminderDue(:final reminder):
        if (focusing) return; // shown when the focus session ends
        _replaceReminder(reminder.copyWith(firedAt: () => t));
        _alerts.add(ReminderAlert(reminder, t));
        voice?.chime('alert');
        _save();
      case MeetingSoon(:final event):
        _announced.add(event.id);
        soonEventId = event.id;
        _soonUntil = event.start;
        if (focusing) {
          flash = Flash(eyebrow: 'SẮP TỚI', title: event.title, meta: _eventMeta(event, t), until: event.start);
        }
        voice?.chime('soft');
      case RecapTime():
        _state.lastRecapDay = dayKey(t);
        if (!night && !focusing && alert == null) {
          screen = Screen.recap;
          _lastInteraction = t;
        }
        _save();
    }
  }

  // ---------------------------------------------------------------- commands

  /// Runs a sentence (from speech or typed); shows "not understood" with examples when it does not parse.
  void handleTranscript(String text, {String lang = 'vi'}) {
    final t = now;
    final c = lang == 'en' ? parseEnglishCommand(text, t) : parseCommand(text, t);
    if (c == null) {
      listening =
          Listening(ListenPhase.notUnderstood, text: text.trim(), until: t.add(const Duration(seconds: 6)), lang: lang);
      _notify();
      return;
    }
    listening = null;
    run(c);
  }

  void run(Command c) {
    final t = now;
    _touch(t);
    if (_askFitFirst(c, t)) return;
    switch (c) {
      case StartTimer(:final duration, :final focus):
        _endFocusEarly(t);
        _alerts.removeWhere((a) => a is TimerDoneAlert); // the old timer's "hết giờ" is answered by the new one
        _state.timer = ActiveTimer(startedAt: t, duration: duration, focus: focus);
        screen = Screen.home;
        flash = focus
            ? null
            : _flash('ĐÃ HẸN GIỜ', durationVi(duration), meta: 'Kết thúc lúc ${hhmm(t.add(duration))}', cool: true);
      case CancelTimer():
        if (_state.timer == null) {
          _show(_flash('HẸN GIỜ', 'Không có hẹn giờ nào đang chạy'));
        } else {
          _endFocusEarly(t);
          _state.timer = null;
          _show(_flash('ĐÃ HỦY', 'Hẹn giờ đã tắt', cool: true));
        }
      case TimeLeft():
        final tm = _state.timer;
        _show(tm == null
            ? _flash('HẸN GIỜ', 'Không có hẹn giờ nào đang chạy')
            : _flash('CÒN LẠI', mmss(tm.remaining(t)), meta: 'Kết thúc lúc ${hhmm(tm.endsAt)}', cool: true));
      case WhatsNext():
        final next = plan.next(t);
        if (next != null) {
          _show(_flash('TIẾP THEO', next.title, meta: _eventMeta(next, t)));
        } else {
          final first = plan.firstTomorrow(t);
          _show(_flash('HÔM NAY HẾT LỊCH', first == null ? 'Không còn gì trong lịch' : 'Ngày mai: ${first.title}',
              meta: first == null ? '' : 'Bắt đầu ${hhmm(first.start)}'));
        }
      case WhatTime():
        _show(_flash('BÂY GIỜ', hhmm(t), meta: shortDate(t)));
      case AddNote(:final text):
        _state.notes.add(Note(id: _id('n', t), text: text, createdAt: t));
        final today = _state.notes.where((n) => sameDay(n.createdAt, t)).length;
        _show(_flash('ĐÃ GHI NHANH', text, meta: '$today việc ghi nhanh hôm nay', cool: true));
      case AddReminder(:final text, :final at):
        if (at == null) {
          askTime = AskTime(text);
          screen = Screen.home;
        } else {
          _addReminder(text, at, t);
        }
      case ShowRecap():
        screen = Screen.recap;
        flash = null;
      case ShowTomorrow():
        screen = Screen.tomorrow;
        flash = null;
      case ScreenOff():
        _manualNightUntil = nightEndsAt(t, settings);
        _nightSuppressedUntil = null;
        peekUntil = null;
        screen = Screen.home;
        flash = null;
      case ScreenOn():
        _manualNightUntil = null;
        peekUntil = null;
        if (isNightTime(t, settings)) _nightSuppressedUntil = nightEndsAt(t, settings);
      case GoHome():
        screen = Screen.home;
        flash = null;
        askTime = null;
      case SplitColumns(:final panels):
        _state.layout = _state.layout.columns(panels);
        screen = Screen.home;
        flash = null;
      case SwapPanel(:final to, :final index, :final from):
        final l = _state.layout;
        final i = index ?? (from != null && l.panels.contains(from) ? l.panels.indexOf(from) : l.panels.length ~/ 2);
        _state.layout = l.withPanel(i, to);
        screen = Screen.home;
        flash = null;
      case SingleColumn():
        final was = _state.layout;
        _state.layout = was.single();
        screen = Screen.home;
        flash = null;
        if (was.split) {
          // "đã lưu bố cục ba cột": the set comes back with "ba cột".
          final kept = 'đã lưu bố cục ${_countWord(was.panels.length)} cột';
          final next = plan.next(t);
          _show(next == null
              ? _flash('DẢI NGÀY', 'Về một cột', meta: kept, cool: true)
              : _flash('TIẾP THEO', next.title, meta: '${_eventMeta(next, t)} · $kept', cool: true));
        }
      case ShowGold():
        screen = Screen.gold;
        _goldSeen = t;
        goldCompare = false;
        flash = null;
      case CompareGoldYesterday():
        screen = Screen.gold;
        _goldSeen = t;
        goldCompare = true;
        flash = null;
      case SetGoldAlert(:final price):
        final now = gold.last;
        _state.goldAlert = GoldAlert.at(price, price: now, now: t);
        _show(_flash('ĐÃ ĐẶT BÁO GIÁ', 'Vàng ${now < price ? 'vượt' : 'xuống dưới'} ${viPrice(price)}',
            meta: 'Giá bây giờ ${viPrice(now)} · báo một lần', cool: true));
      case BusyAt(:final at):
        _show(_busyFlash(at, t));
      case ShowWeek():
        screen = Screen.week;
        freeSlotsDay = null;
        flash = null;
      case FreeSlots(:final weekday):
        screen = Screen.week;
        freeSlotsDay = weekdayAhead(t, weekday);
        flash = null;
      case ShowMonth():
        screen = Screen.month;
        countdownTo = null;
        flash = null;
      case DaysUntil(:final query):
        final e = _findAhead(query, t);
        if (e == null) {
          _show(_flash('KHÔNG THẤY', 'Không có “$query” trong lịch', meta: 'Thử nói đúng tên trong lịch'));
        } else {
          countdownTo = e;
          screen = Screen.month;
          flash = null;
        }
      case NotSupported(:final what):
        _show(_flash('CHƯA LÀM ĐƯỢC', what));
    }
    _save();
    _notify();
  }

  /// Answers the "when?" question for a reminder said without a time; null drops it.
  void answerAskTime(Duration? after) {
    final a = askTime;
    askTime = null;
    final t = now;
    _touch(t);
    if (a != null && after != null) {
      _addReminder(a.text, t.add(after), t);
      _save();
    }
    _notify();
  }

  void _addReminder(String text, DateTime at, DateTime t) {
    _state.reminders.add(Reminder(id: _id('r', t), text: text, at: at, createdAt: t));
    final day = sameDay(at, t) ? '' : ' ngày mai';
    _show(_flash('ĐÃ HẸN NHẮC', text, meta: '${hhmm(at)}$day · còn ${durationVi(at.difference(t))}', cool: true));
  }

  // ---------------------------------------------------------------- touch

  /// Mic button or long press: start listening.
  void talk() {
    final t = now;
    _touch(t);
    final v = voice;
    _heardTimer?.cancel();
    if (v == null || !v.ready) {
      log('talk: voice not ready');
      listening = Listening(ListenPhase.unavailable, until: t.add(const Duration(seconds: 4)));
    } else {
      final id = 'l${++_listenSeq}';
      final lang = listenLang;
      log('talk: listen $id${lang == 'vi' ? '' : ' ($lang)'}');
      listening = Listening(ListenPhase.listening, id: id, lang: lang);
      v.listen(id, lang: lang);
    }
    _notify();
  }

  /// The VI/EN switch: changes the language of the next voice commands, and says so.
  void toggleVoiceLang() {
    final t = now;
    _touch(t);
    _state.voiceLang = voiceLang == 'en' ? 'vi' : 'en';
    log('voice lang: ${_state.voiceLang}');
    _show(_state.voiceLang == 'en'
        ? _flash('LỆNH TIẾNG ANH', '“Set a timer for 25 minutes”', meta: 'Giọng nói gửi lên cloud để nhận dạng', cool: true)
        : _flash('LỆNH TIẾNG VIỆT', '“Hẹn giờ 10 phút”', meta: 'Nhận dạng ngay trên máy', cool: true));
    _save();
    _notify();
  }

  /// Tap on the listening overlay. While listening it means "I'm done": what was said so far is used, and if nothing
  /// was said the overlay just closes (people tap to stop, like a recorder). Otherwise it closes the notice.
  void tapOverlay() {
    final l = listening;
    if (l == null) return;
    if (l.phase != ListenPhase.listening) return cancelTalk();
    final t = now;
    _touch(t);
    log('talk: finish ${l.id}');
    voice?.finish();
    // The answer is a final or a timeout within a second; the deadline only covers a service that never answers.
    listening = l.copyWith(phase: ListenPhase.thinking, until: t.add(finishTimeout));
    _notify();
  }

  /// Stops listening and drops whatever the service would still send, or closes a notice.
  void cancelTalk() {
    final l = listening;
    if (l == null) return;
    if (l.phase == ListenPhase.listening || l.phase == ListenPhase.thinking) {
      log('talk: cancel ${l.id}');
      voice?.cancel();
    }
    _heardTimer?.cancel();
    listening = null;
    _notify();
  }

  void alertAction(AlertAction action) {
    final a = alert;
    if (a == null) return;
    final t = now;
    _touch(t);
    _alerts.removeAt(0);
    switch (a) {
      case TimerDoneAlert(:final timer) when action == AlertAction.primary && layout.split && !timer.focus:
        // "+10 phút" in the timer column; the columns stay as they are.
        _state.timer = ActiveTimer(startedAt: t, duration: const Duration(minutes: 10), focus: false);
      case TimerDoneAlert(:final timer) when action == AlertAction.primary:
        // focus: "Nghỉ 5 phút"; plain timer: "Thêm 5 phút"
        _state.timer = ActiveTimer(startedAt: t, duration: const Duration(minutes: 5), focus: false);
        _show(timer.focus
            ? _flash('NGHỈ 5 PHÚT', 'Đứng dậy, uống nước', meta: 'Quay lại lúc ${hhmm(t.add(const Duration(minutes: 5)))}',
                cool: true)
            : _flash('THÊM 5 PHÚT', 'Kết thúc lúc ${hhmm(t.add(const Duration(minutes: 5)))}', cool: true));
      case TimerDoneAlert():
        break;
      case GoldCrossedAlert() when action == AlertAction.primary:
        screen = Screen.gold; // "Xem chart"
        _goldSeen = t;
        goldCompare = false;
      case GoldCrossedAlert():
        _state.goldAlert = null; // "Tắt báo"
      case ReminderAlert(:final reminder):
        final current = _state.reminders.where((r) => r.id == reminder.id).firstOrNull ?? reminder;
        _replaceReminder(action == AlertAction.primary
            ? current.copyWith(doneAt: () => t)
            : current.copyWith(at: t.add(const Duration(minutes: 10)), firedAt: () => null));
    }
    _save();
    _notify();
  }

  /// Ticks a note or reminder done (or not) on the recap screen.
  void toggleDone(String id) {
    final t = now;
    _touch(t);
    final i = _state.notes.indexWhere((n) => n.id == id);
    if (i >= 0) {
      final n = _state.notes[i];
      _state.notes[i] = n.copyWith(doneAt: () => n.done ? null : t);
    } else {
      final r = _state.reminders.where((r) => r.id == id).firstOrNull;
      if (r != null) _replaceReminder(r.copyWith(doneAt: () => r.done ? null : t));
    }
    _save();
    _notify();
  }

  /// Swipe up: tomorrow, from the strip or from the recap ("cuối ngày, vuốt lên xem ngày mai").
  void swipeUp() {
    _touch(now);
    if (screen == Screen.home || screen == Screen.recap) screen = Screen.tomorrow;
    _notify();
  }

  /// A tap on a day of the week view: that day's events.
  void openWeekDay(DateTime d) {
    _touch(now);
    openDay = dayOf(d);
    screen = Screen.day;
    _notify();
  }

  void swipeDown() {
    _touch(now);
    screen = Screen.home;
    _notify();
  }

  /// Tap while the screen is dark: show the clock for [peekFor].
  void tapNight() {
    final t = now;
    _touch(t);
    peekUntil = t.add(peekFor);
    _notify();
  }

  /// Any touch keeps a non-home screen open a little longer.
  void touched() => _touch(now);

  // ---------------------------------------------------------------- voice

  void _onVoice(VoiceEvent e) {
    final l = listening;
    final t = now;
    switch (e) {
      case VoiceReady(:final model, :final stt, :final wake, :final langs):
        log('voice: ready ($model, stt $stt, wake $wake, langs ${langs.join('/')})');
        _wakeSent = null;
        _voiceLangs = langs;
      case VoiceWake(:final keyword):
        final busy = l != null &&
            (l.phase == ListenPhase.listening || l.phase == ListenPhase.thinking || l.phase == ListenPhase.heard);
        if (!wakeWanted || busy) {
          log('wake: $keyword ignored${busy ? ' (already listening)' : ''}');
          return;
        }
        log('wake: $keyword');
        talk();
        return;
      case VoiceListening():
        break;
      case VoiceLevel(:final db):
        if (l == null || l.phase != ListenPhase.listening) return;
        listening = l.copyWith(level: db);
      case VoiceProcessing(:final id):
        if (l == null || l.id != id || l.phase != ListenPhase.listening) return;
        listening = l.copyWith(phase: ListenPhase.thinking);
      case VoiceFinal(:final id, :final text, :final sttMs, :final audioMs, :final engine):
        if (l == null || l.id != id) return;
        log('voice: "$text" (audio ${audioMs}ms, stt ${sttMs}ms${engine.isEmpty ? '' : ', $engine'})');
        if (text.trim().isEmpty) {
          listening = l.copyWith(phase: ListenPhase.noSpeech, until: t.add(const Duration(seconds: 4)));
        } else if (heardHold == Duration.zero) {
          handleTranscript(text, lang: l.lang);
          return;
        } else {
          listening = l.copyWith(phase: ListenPhase.heard, text: text);
          _heardTimer?.cancel();
          _heardTimer = Timer(heardHold, () => handleTranscript(text, lang: l.lang));
        }
      case VoiceTimeout(:final id):
        if (l == null || l.id != id) return;
        log('voice: nothing heard for $id');
        // After a tap to finish, nothing heard means the user changed their mind: just close.
        listening = l.phase == ListenPhase.thinking
            ? null
            : l.copyWith(phase: ListenPhase.noSpeech, until: t.add(const Duration(seconds: 4)));
      case VoiceError(:final message):
        log('voice error: $message');
        if (l == null || (l.phase != ListenPhase.listening && l.phase != ListenPhase.thinking)) return;
        listening = l.copyWith(phase: ListenPhase.unavailable, until: t.add(const Duration(seconds: 4)));
      case VoiceDisconnected():
        _wakeSent = null;
        if (l == null || (l.phase != ListenPhase.listening && l.phase != ListenPhase.thinking)) break;
        listening = l.copyWith(phase: ListenPhase.unavailable, until: t.add(const Duration(seconds: 4)));
    }
    _notify();
  }

  // ---------------------------------------------------------------- ask before a timer that runs into a meeting (demo 6)

  /// How long the question waits for a tap. Then it is dropped, no timer starts (the user may have walked away; a
  /// timer they did not choose is worse than none), and a short flash says so.
  static const askFitTimeout = Duration(seconds: 20);

  /// The question on screen ("HẸN GIỜ 25 PHÚT?"), if any.
  AskFit? askFit;

  /// The timer started from "Hẹn N phút" and the meeting it ends before, for the focus screen's line.
  ActiveTimer? _fitTimer;
  CalendarEvent? _fitMeeting;

  /// True while an answer starts its timer through [run], so it does not ask again.
  bool _askFitAnswering = false;

  /// "Hết giờ lúc 10:27, trước giờ họp 3 phút" while the timer started from the fit runs; null otherwise.
  String? get fitDndLine {
    final tm = _state.timer;
    final m = _fitMeeting;
    return tm != null && m != null && identical(tm, _fitTimer) ? fitLine(tm.endsAt, m) : null;
  }

  /// Runs first in [run]: a timer that would run into a meeting asks instead of starting (true: asked). Any command
  /// drops a question still open.
  bool _askFitFirst(Command cmd, DateTime t) {
    askFit = null;
    if (_askFitAnswering || cmd is! StartTimer || !clockValid) return false;
    final m = meetingInTheWay(plan, t, cmd.duration);
    if (m == null) return false;
    askFit = AskFit(asked: cmd.duration, focus: cmd.focus, meeting: m, at: t, fit: fitBefore(m.start.difference(t)));
    screen = Screen.home;
    flash = null;
    _notify();
    return true;
  }

  /// A tap on the question: start the fitted length, the length asked for, or nothing. The kind (focus or not) stays.
  void answerAskFit(AskFitAnswer answer) {
    final a = askFit;
    askFit = null;
    _touch(now);
    if (a == null) return _notify();
    final length = switch (answer) {
      AskFitAnswer.fit when a.canFit => a.fit,
      AskFitAnswer.asked => a.asked,
      _ => null,
    };
    if (length == null) return _notify();
    _askFitAnswering = true;
    try {
      run(StartTimer(length, focus: a.focus));
    } finally {
      _askFitAnswering = false;
    }
    if (length != a.fit) return;
    _fitTimer = _state.timer;
    _fitMeeting = a.meeting;
    final end = _state.timer!.endsAt;
    if (!a.focus) {
      flash = _flash('ĐÃ HẸN GIỜ', timerLength(length),
          meta: 'Kết thúc lúc ${hhmm(end)} · trước giờ họp ${clockMinutes(end, a.meeting.start)} phút', cool: true);
    }
    _notify();
  }

  void _expireAskFit(DateTime t) {
    final a = askFit;
    if (a == null || t.difference(a.at) < askFitTimeout) return;
    askFit = null;
    _show(_flash('HẸN GIỜ', 'Chưa hẹn ${timerLength(a.asked)}', meta: 'Không thấy trả lời · nói lại nếu vẫn cần'));
  }

  // ---------------------------------------------------------------- helpers

  void _touch(DateTime t) => _lastInteraction = t;

  /// What is on in the hour from [at]: the first event there, or free and what comes after.
  Flash _busyFlash(DateTime at, DateTime t) {
    final end = at.add(const Duration(hours: 1));
    final day = plan.on(at);
    final hits = day.where((e) => e.start.isBefore(end) && e.end.isAfter(at)).toList();
    final when = sameDay(at, t)
        ? 'LÚC ${hhmm(at)}'
        : sameDay(at, t.add(const Duration(days: 1)))
            ? 'MAI ${hhmm(at)}'
            : '${shortDate(at).toUpperCase()} ${hhmm(at)}';
    if (hits.isNotEmpty) {
      final e = hits.first;
      final more = hits.length > 1 ? ' · thêm ${hits.length - 1} lịch' : '';
      return _flash('$when · CÓ LỊCH', e.title, meta: '${hhmm(e.start)}–${hhmm(e.end)}$more');
    }
    final after = day.where((e) => !e.start.isBefore(end)).firstOrNull;
    return _flash('$when · RẢNH', 'Không có lịch',
        meta: after == null ? 'Sau đó cũng trống' : 'Tiếp theo ${hhmm(after.start)} ${after.title}', cool: true);
  }

  Flash _flash(String eyebrow, String title, {String meta = '', bool cool = false}) =>
      Flash(eyebrow: eyebrow, title: title, meta: meta, cool: cool, until: now.add(flashFor));

  /// Shows [f] on the home screen (the strip or the focus card).
  void _show(Flash f) {
    flash = f;
    screen = Screen.home;
  }

  /// A focus session replaced or cancelled before its end is kept as not completed.
  void _endFocusEarly(DateTime t) {
    final tm = _state.timer;
    if (tm != null && tm.focus && !tm.isDone(t)) {
      _state.sessions.add(FocusSession(start: tm.startedAt, end: t, completed: false));
    }
  }

  void _replaceReminder(Reminder r) {
    final i = _state.reminders.indexWhere((x) => x.id == r.id);
    if (i >= 0) _state.reminders[i] = r;
  }

  String _id(String prefix, DateTime t) => '$prefix${t.microsecondsSinceEpoch}-${_state.notes.length + _state.reminders.length}';

  static String _countWord(int n) => const {2: 'hai', 3: 'ba'}[n] ?? '$n';

  static String _eventMeta(CalendarEvent e, DateTime t) =>
      [hhmm(e.start), 'còn ${durationVi(e.start.difference(t))}', if (e.details.isNotEmpty) e.details].join(' · ');

  void _save() {
    store.save(_state).then((_) {
      if (_saveFailedAt != null) {
        _saveFailedAt = null;
        _notify();
      }
    }, onError: (Object e) {
      log('save failed: $e');
      _saveFailedAt = now;
      _notify();
    });
  }
}
