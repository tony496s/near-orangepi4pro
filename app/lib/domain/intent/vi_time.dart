import 'vi_numbers.dart';

/// Durations and clock times said in Vietnamese.
///
/// Durations: "mười lăm phút", "1 giờ", "một tiếng rưỡi", "nửa tiếng", "hai giờ mười phút", "30 giây".
/// Clock times: "ba giờ chiều", "tám giờ rưỡi sáng", "mười giờ mười lăm", "ba giờ kém mười lăm", "15 giờ 30".

const _hourWords = {'giờ', 'tiếng'};

/// A duration starting at [start]: (duration, tokens consumed), or null.
({Duration duration, int length})? readDuration(List<String> tokens, int start) {
  if (start + 1 < tokens.length && tokens[start] == 'nửa' && _hourWords.contains(tokens[start + 1])) {
    return (duration: const Duration(minutes: 30), length: 2);
  }
  final n = readNumber(tokens, start);
  if (n == null) return null;
  var i = start + n.length;
  if (i >= tokens.length) return null;
  final unit = tokens[i];
  if (unit == 'phút') return (duration: Duration(minutes: n.value), length: i + 1 - start);
  if (unit == 'giây') return (duration: Duration(seconds: n.value), length: i + 1 - start);
  if (!_hourWords.contains(unit)) return null;
  i++;
  var minutes = n.value * 60;
  if (i < tokens.length && tokens[i] == 'rưỡi') {
    return (duration: Duration(minutes: minutes + 30), length: i + 1 - start);
  }
  final m = readNumber(tokens, i);
  if (m != null && m.value < 60) {
    final j = i + m.length;
    if (j < tokens.length && tokens[j] == 'phút') {
      return (duration: Duration(minutes: minutes + m.value), length: j + 1 - start);
    }
  }
  return (duration: Duration(minutes: minutes), length: i - start);
}

/// Part of the day said after a clock time.
enum DayPart { morning, noon, afternoon, evening, night }

const _dayParts = {
  'sáng': DayPart.morning,
  'trưa': DayPart.noon,
  'chiều': DayPart.afternoon,
  'tối': DayPart.evening,
  'đêm': DayPart.night,
};

typedef ClockTime = ({int hour, int minute, DayPart? part, int length});

/// A clock time starting at [start] ("ba giờ chiều"), or null. The hour is as said (1-24); see [resolveClockTime].
ClockTime? readClockTime(List<String> tokens, int start) {
  final h = readNumber(tokens, start);
  if (h == null || h.value > 24) return null;
  var i = start + h.length;
  if (i >= tokens.length || tokens[i] != 'giờ') return null;
  i++;
  var hour = h.value;
  var minute = 0;
  if (i < tokens.length && tokens[i] == 'rưỡi') {
    minute = 30;
    i++;
  } else if (i < tokens.length && tokens[i] == 'kém') {
    final m = readNumber(tokens, i + 1);
    if (m != null && m.value > 0 && m.value < 60) {
      hour = hour == 0 ? 23 : hour - 1;
      minute = 60 - m.value;
      i += 1 + m.length;
      if (i < tokens.length && tokens[i] == 'phút') i++;
    }
  } else {
    final m = readNumber(tokens, i);
    if (m != null && m.value < 60) {
      minute = m.value;
      i += m.length;
      if (i < tokens.length && tokens[i] == 'phút') i++;
    }
  }
  DayPart? part;
  if (i < tokens.length && _dayParts.containsKey(tokens[i])) {
    part = _dayParts[tokens[i]];
    i++;
    // "chiều nay", "sáng mai" are read by the caller; only "nay" is consumed here.
    if (i < tokens.length && tokens[i] == 'nay') i++;
  }
  return (hour: hour, minute: minute, part: part, length: i - start);
}

/// The next moment matching [t] after [now]. [tomorrow] forces the next day.
///
/// With a part of the day, "ba giờ chiều" is 15:00. Without one, people mean the next sensible occurrence during
/// waking hours: at 14:12, "ba giờ" is 15:00 today; "tám giờ" is 20:00 today; nobody sets a reminder for 03:00.
DateTime resolveClockTime(ClockTime t, DateTime now, {bool tomorrow = false}) {
  final base = DateTime(now.year, now.month, now.day);
  int hourFor(DayPart part) {
    final h = t.hour % 24;
    switch (part) {
      case DayPart.morning:
        return h == 12 ? 0 : h;
      case DayPart.noon:
        return h <= 2 ? h + 12 : h; // "1 giờ trưa" is 13:00, "11 giờ trưa" is 11:00
      case DayPart.afternoon:
      case DayPart.evening:
        return h < 12 ? h + 12 : h;
      case DayPart.night:
        return h == 12 ? 0 : (h >= 9 && h < 12 ? h + 12 : h);
    }
  }

  DateTime at(DateTime day, int hour) => DateTime(day.year, day.month, day.day, hour, t.minute);

  if (t.part != null) {
    final hour = hourFor(t.part!);
    if (tomorrow) return at(base.add(const Duration(days: 1)), hour);
    final today = at(base, hour);
    return today.isAfter(now) ? today : at(base.add(const Duration(days: 1)), hour);
  }
  final h = t.hour % 24;
  final candidates = <int>{if (h >= 7) h, if (h < 12) h + 12}.toList()..sort();
  if (candidates.isEmpty) candidates.add(h);
  if (tomorrow) return at(base.add(const Duration(days: 1)), candidates.first);
  for (final c in candidates) {
    final d = at(base, c);
    if (d.isAfter(now)) return d;
  }
  return at(base.add(const Duration(days: 1)), candidates.first);
}
