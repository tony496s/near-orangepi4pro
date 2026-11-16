import 'commands.dart';
import 'vi_text.dart' show hasAny, hasPhrase, indexOfPhrase;
import 'vi_time.dart' show ClockTime, DayPart, resolveClockTime;

/// English commands, for the EN side of the VI/EN switch: the same [Command]s as `parseCommand`, read from English.
///
/// The words come from Deepgram nova-3 through Harness: sentence case, punctuation, and numbers as digits or words
/// ("Set a timer for 10 minutes.", "for ten minutes"); both are read. Free text (notes, reminders) keeps the case
/// Deepgram gave it, so names stay capitalized.
Command? parseEnglishCommand(String text, DateTime now) {
  final raw = enTokenize(text);
  if (raw.isEmpty) return null;
  final t = [for (final w in raw) w.toLowerCase()];
  return _note(t, raw) ??
      _reminder(t, raw, now) ??
      _screen(t) ??
      _unsupported(t) ??
      _cancelTimer(t) ??
      _timeLeft(t) ??
      _startTimer(t) ??
      _simple(t);
}

/// Example sentences shown when an English sentence is not understood.
const englishExamples = ['Set a timer for 25 minutes', 'Add a note: buy milk', 'Remind me to call Lan at 3 pm'];

/// Words in their original case, punctuation removed: "p.m." -> "pm", "3:30" -> "3 30", "10min" -> "10 min",
/// "what's" -> "what is", "twenty-five" -> "twenty five", and a leading "Hey Near" dropped.
List<String> enTokenize(String text) {
  var s = text.replaceAll('’', "'");
  s = s.replaceAllMapped(RegExp(r'\b([ap])\.\s?m\b\.?', caseSensitive: false), (m) => ' ${m[1]!.toLowerCase()}m ');
  s = s.replaceAllMapped(RegExp(r'(\d{1,2}):(\d{2})\b'), (m) => ' ${m[1]} ${m[2]} ');
  s = s.replaceAllMapped(RegExp(r'(\d)(am|pm|min|mins|h|hr|hrs)\b', caseSensitive: false), (m) => '${m[1]} ${m[2]}');
  s = s.replaceAllMapped(RegExp(r"\b(what|it|that|there|here|how|who)'s\b", caseSensitive: false), (m) => '${m[1]} is');
  s = s.replaceAll(RegExp(r'''[,.!?;:"“”‘()\[\]…\-–—/]'''), ' ').replaceAll("'", '');
  final tokens = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  for (final p in const [
    ['hey', 'near'],
    ['hi', 'near'],
    ['ok', 'near'],
    ['okay', 'near'],
  ]) {
    if (tokens.length >= p.length && indexOfPhrase([for (final w in tokens.take(p.length)) w.toLowerCase()], p) == 0) {
      return tokens.sublist(p.length);
    }
  }
  return tokens;
}

// ---------------------------------------------------------------- numbers, durations, clock times

const _ones = {
  'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, //
  'ten': 10, 'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15, 'sixteen': 16, //
  'seventeen': 17, 'eighteen': 18, 'nineteen': 19,
};
const _tens = {
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
};

/// A number at [i]: digits, "fifteen", "forty five". With [article], "a"/"an" count as one ("an hour").
({int value, int length})? readEnNumber(List<String> t, int i, {bool article = false}) {
  if (i >= t.length) return null;
  final w = t[i];
  final digits = int.tryParse(w);
  if (digits != null) return (value: digits, length: 1);
  if (article && (w == 'a' || w == 'an')) return (value: 1, length: 1);
  if (_ones.containsKey(w)) return (value: _ones[w]!, length: 1);
  if (_tens.containsKey(w)) {
    final next = i + 1 < t.length ? _ones[t[i + 1]] : null;
    return next != null && next > 0 && next < 10 ? (value: _tens[w]! + next, length: 2) : (value: _tens[w]!, length: 1);
  }
  return null;
}

const _hourUnits = {'hour', 'hours', 'hr', 'hrs', 'h'};
const _minuteUnits = {'minute', 'minutes', 'min', 'mins'};
const _secondUnits = {'second', 'seconds', 'sec', 'secs'};

/// A duration at [i]: "10 minutes", "an hour", "1 hour and 30 minutes", "an hour and a half", "half an hour",
/// "90 seconds", "a 10 minute" (as in "a 10 minute timer").
({Duration duration, int length})? readEnDuration(List<String> t, int i) {
  if (indexOfPhrase(t, const ['half', 'an', 'hour'], i) == i) return (duration: const Duration(minutes: 30), length: 3);
  if (indexOfPhrase(t, const ['half', 'hour'], i) == i) return (duration: const Duration(minutes: 30), length: 2);
  final n = readEnNumber(t, i, article: true);
  if (n == null) return null;
  var j = i + n.length;
  if (j >= t.length) return null;
  final unit = t[j];
  if (_hourUnits.contains(unit)) {
    var d = Duration(hours: n.value);
    j++;
    if (indexOfPhrase(t, const ['and', 'a', 'half'], j) == j) {
      return (duration: d + const Duration(minutes: 30), length: j + 3 - i);
    }
    final and = j < t.length && t[j] == 'and' ? 1 : 0;
    final m = readEnNumber(t, j + and);
    if (m != null && j + and + m.length < t.length && _minuteUnits.contains(t[j + and + m.length])) {
      d += Duration(minutes: m.value);
      j += and + m.length + 1;
    }
    return (duration: d, length: j - i);
  }
  if (_minuteUnits.contains(unit)) return (duration: Duration(minutes: n.value), length: j + 1 - i);
  if (_secondUnits.contains(unit)) return (duration: Duration(seconds: n.value), length: j + 1 - i);
  return null;
}

/// A clock time at [i]: "3 pm", "3 30 pm" ("3:30 PM"), "15 00", "8 oclock", "half past 3", "quarter to 4", "noon",
/// "midnight", "8 in the evening". A bare number counts only with [bare] (after "at": "at 3").
ClockTime? readEnClock(List<String> t, int i, {bool bare = false}) {
  if (i >= t.length) return null;
  if (t[i] == 'noon' || t[i] == 'midday') return (hour: 12, minute: 0, part: DayPart.noon, length: 1);
  if (t[i] == 'midnight') return (hour: 12, minute: 0, part: DayPart.night, length: 1);
  var j = i;
  var minute = 0;
  var past = 0; // "half past 3": the hour comes after
  if (t[j] == 'half' && j + 1 < t.length && t[j + 1] == 'past') {
    minute = 30;
    j += 2;
    past = 1;
  } else if (t[j] == 'quarter' && j + 1 < t.length && (t[j + 1] == 'past' || t[j + 1] == 'to')) {
    minute = t[j + 1] == 'past' ? 15 : -15;
    j += 2;
    past = 1;
  }
  final h = readEnNumber(t, j);
  if (h == null || h.value < 0 || h.value > 24) return null;
  var hour = h.value;
  j += h.length;
  var marked = past == 1;
  if (past == 0) {
    final m = readEnNumber(t, j);
    if (m != null && m.value < 60 && (t[j].length == 2 || m.value >= 10)) {
      minute = m.value;
      j += m.length;
      marked = true;
    } else if (j < t.length && (t[j] == 'oclock')) {
      j++;
      marked = true;
    }
  }
  if (minute < 0) {
    hour = hour == 0 ? 23 : hour - 1;
    minute += 60;
  }
  DayPart? part;
  if (j < t.length && (t[j] == 'am' || t[j] == 'pm')) {
    part = t[j] == 'am' ? DayPart.morning : DayPart.afternoon;
    j++;
    marked = true;
  } else if (indexOfPhrase(t, const ['in', 'the'], j) == j && j + 2 < t.length) {
    part = _parts[t[j + 2]];
    if (part != null) j += 3;
  } else if (j < t.length && t[j] == 'tonight') {
    part = DayPart.evening;
    j++;
  }
  if (!marked && part == null && !bare) return null;
  return (hour: hour, minute: minute, part: part, length: j - i);
}

// ---------------------------------------------------------------- rules

const _parts = {'morning': DayPart.morning, 'afternoon': DayPart.afternoon, 'evening': DayPart.evening};

const _notePrefixes = [
  ['add', 'a', 'note'],
  ['add', 'note'],
  ['take', 'a', 'note'],
  ['make', 'a', 'note'],
  ['note', 'down'],
  ['note'],
  ['write', 'down'],
  ['jot', 'down'],
];

Command? _note(List<String> t, List<String> raw) {
  for (final p in _notePrefixes) {
    if (indexOfPhrase(t, p) == 0) {
      var k = p.length;
      while (k < t.length && const {'that', 'saying', 'to', 'self'}.contains(t[k])) {
        k++;
      }
      return k >= t.length ? null : AddNote(_sentence(raw.sublist(k)));
    }
  }
  return null;
}

Command? _reminder(List<String> t, List<String> raw, DateTime now) {
  final start = t.indexOf('remind');
  if (start < 0 || start > 1 || (start == 1 && t[0] != 'please')) return null;
  var k = start + 1;
  if (k < t.length && const {'me', 'us'}.contains(t[k])) k++;
  if (k < t.length && const {'to', 'that', 'about', 'of'}.contains(t[k])) k++;
  var body = t.sublist(k);
  var bodyRaw = raw.sublist(k);

  void drop(int from, int count) {
    body = [...body.sublist(0, from), ...body.sublist(from + count)];
    bodyRaw = [...bodyRaw.sublist(0, from), ...bodyRaw.sublist(from + count)];
  }

  var tomorrow = false;
  DayPart? tomorrowPart;
  final tm = body.indexOf('tomorrow');
  if (tm >= 0) {
    tomorrow = true;
    tomorrowPart = tm + 1 < body.length ? _parts[body[tm + 1]] : null;
    drop(tm, tomorrowPart == null ? 1 : 2);
  }
  DateTime? at;
  for (var i = 0; i < body.length && at == null; i++) {
    final w = body[i];
    if (w == 'in' || w == 'after') {
      final d = readEnDuration(body, i + 1);
      if (d != null) {
        at = now.add(d.duration);
        drop(i, 1 + d.length);
        continue;
      }
    }
    final d = readEnDuration(body, i);
    if (d != null && indexOfPhrase(body, const ['from', 'now'], i + d.length) == i + d.length) {
      at = now.add(d.duration);
      drop(i, d.length + 2);
      continue;
    }
    final lead = w == 'at' || w == 'by' ? 1 : 0;
    final c = readEnClock(body, i + lead, bare: lead == 1);
    if (c != null) {
      at = resolveClockTime(c, now, tomorrow: tomorrow);
      drop(i, lead + c.length);
    }
  }
  if (at == null && tomorrow) {
    // "remind me tomorrow (afternoon) to …" without a clock time: 9:00, 15:00 or 19:00 the next day.
    final hour = switch (tomorrowPart) {
      DayPart.afternoon => 3,
      DayPart.evening => 7,
      _ => 9,
    };
    at = resolveClockTime(
      (hour: hour, minute: 0, part: tomorrowPart ?? DayPart.morning, length: 0),
      now,
      tomorrow: true,
    );
  }
  if (at != null) {
    // "at 5 tonight", "this afternoon at 3": said with the time, not part of the reminder.
    for (final w in const ['tonight', 'today']) {
      final i = body.indexOf(w);
      if (i >= 0) drop(i, 1);
    }
    final i = body.indexOf('this');
    if (i >= 0 && i + 1 < body.length && _parts.containsKey(body[i + 1])) drop(i, 2);
  }
  while (body.isNotEmpty && const {'to', 'at', 'in', 'on', 'please', 'by', 'the'}.contains(body.last)) {
    drop(body.length - 1, 1);
  }
  while (body.isNotEmpty && const {'to', 'that', 'about'}.contains(body.first)) {
    drop(0, 1);
  }
  if (body.isEmpty) return null;
  return AddReminder(_sentence(bodyRaw), at);
}

Command? _screen(List<String> t) {
  final screen = t.contains('screen') || t.contains('display');
  if ((screen && t.contains('off')) ||
      hasAny(t, ['good night', 'goodnight', 'night mode', 'sleep mode', 'go to sleep'])) {
    return const ScreenOff();
  }
  if ((screen && t.contains('on')) || hasPhrase(t, 'wake up')) return const ScreenOn();
  return null;
}

Command? _unsupported(List<String> t) {
  final verb = hasAny(t, ['move', 'reschedule', 'postpone', 'push back', 'cancel', 'delete']);
  if (verb && hasAny(t, ['meeting', 'event', 'appointment', 'call'])) {
    return const NotSupported('Dời hay hủy lịch họp chưa làm được trên bản demo');
  }
  return null;
}

const _timerWords = ['timer', 'countdown', 'count down', 'focus', 'focusing', 'pomodoro'];
const _stopVerbs = ['cancel', 'stop', 'end', 'clear', 'delete', 'remove', 'kill', 'reset', 'turn off'];

Command? _cancelTimer(List<String> t) =>
    hasAny(t, _stopVerbs) && (hasAny(t, _timerWords) || hasPhrase(t, 'session')) ? const CancelTimer() : null;

Command? _timeLeft(List<String> t) {
  if (hasAny(t, [
    'time left',
    'minutes left',
    'how long left',
    'how much longer',
    'how much time',
    'time remaining',
    'how many minutes',
    'how long until the timer',
  ])) {
    return const TimeLeft();
  }
  return null;
}

Command? _startTimer(List<String> t) {
  if (!hasAny(t, _timerWords)) return null;
  final focus = hasAny(t, ['focus', 'focusing', 'pomodoro']);
  for (var i = 0; i < t.length; i++) {
    final d = readEnDuration(t, i);
    if (d != null && d.duration > Duration.zero) return StartTimer(d.duration, focus: focus);
  }
  // "start focusing", "start a focus session": a classic 25-minute session.
  return focus ? const StartTimer(Duration(minutes: 25), focus: true) : null;
}

Command? _simple(List<String> t) {
  if (hasAny(t, [
    'recap',
    'summary',
    'summarize',
    'how was today',
    'how was my day',
    'how did today go',
    'what did i do today',
    'wrap up',
  ])) {
    return const ShowRecap();
  }
  if (t.contains('tomorrow')) return const ShowTomorrow();
  if (hasAny(t, ['next', 'coming up', 'my schedule', 'agenda', 'my calendar', 'what do i have'])) {
    return const WhatsNext();
  }
  if (hasAny(t, ['what time is it', 'what is the time', 'time is it', 'current time'])) return const WhatTime();
  if (hasAny(t, ['go home', 'go back', 'home screen', 'main screen', 'back to home']) ||
      (t.length <= 2 && const {'close', 'back', 'home', 'done', 'dismiss'}.contains(t.first))) {
    return const GoHome();
  }
  return null;
}

/// Words joined back, first letter capitalized; the case Deepgram gave (names) is kept.
String _sentence(List<String> raw) {
  final s = raw.join(' ');
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
