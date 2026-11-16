import '../../core/clock.dart' show sameDay;
import '../strip_layout.dart';
import 'commands.dart';
import 'vi_numbers.dart';
import 'vi_text.dart';
import 'vi_time.dart';

/// Turns a transcript into a [Command], or null when it is not understood.
///
/// Rules are checked in order. Commands that start with a verb and carry free text (note, reminder) come first, so
/// "ghi lại: tắt màn hình ở phòng họp" is a note, not "screen off".
Command? parseCommand(String text, DateTime now) {
  final t = tokenize(text);
  if (t.isEmpty) return null;
  return _note(t) ??
      _reminder(t, now) ??
      _screen(t) ??
      _layout(t) ??
      _gold(t) ??
      _calendar(t, now) ??
      _unsupported(t) ??
      _cancelTimer(t) ??
      _timeLeft(t) ??
      _startTimer(t) ??
      _simple(t);
}

/// Example sentences shown when a sentence is not understood.
const examples = ['Hẹn giờ 25 phút để tập trung', 'Ghi lại: mua sữa trên đường về', 'Nhắc anh gọi chị Lan lúc 3 giờ'];

const _notePrefixes = [
  ['ghi', 'lại'],
  ['ghi', 'nhanh'],
  ['ghi', 'chú'],
  ['ghi', 'nhớ'],
  ['lưu', 'lại'],
  ['note'],
];

Command? _note(List<String> t) {
  for (final p in _notePrefixes) {
    if (indexOfPhrase(t, p) == 0) {
      var rest = t.sublist(p.length);
      if (rest.isNotEmpty && (rest.first == 'là' || rest.first == 'rằng')) rest = rest.sublist(1);
      return rest.isEmpty ? null : AddNote(sentence(rest));
    }
  }
  return null;
}

const _selfPronouns = {'anh', 'em', 'tôi', 'mình', 'tớ', 'tui'};

Command? _reminder(List<String> t, DateTime now) {
  final start = t.indexOf('nhắc');
  // "nhắc" must lead the sentence (optionally after "hãy"/"nhớ"), otherwise "ghi lại: nhắc khách ..." would be one.
  if (start < 0 || start > 1 || (start == 1 && t[0] != 'hãy' && t[0] != 'nhớ')) return null;
  var body = t.sublist(start + 1);
  if (body.isNotEmpty && _selfPronouns.contains(body.first)) body = body.sublist(1);
  if (body.isNotEmpty && (body.first == 'là' || body.first == 'việc')) body = body.sublist(1);

  var tomorrow = false;
  for (final word in const [['ngày', 'mai'], ['sáng', 'mai'], ['chiều', 'mai'], ['tối', 'mai']]) {
    final i = indexOfPhrase(body, word);
    if (i >= 0) {
      tomorrow = true;
      // keep the part of day ("chiều") for the time, drop "mai"/"ngày mai"
      body = [...body.sublist(0, word[0] == 'ngày' ? i : i + 1), ...body.sublist(i + 2)];
    }
  }
  if (body.isNotEmpty && body.last == 'mai' && body.length > 1) {
    tomorrow = true;
    body = body.sublist(0, body.length - 1);
  }

  DateTime? at;
  var textTokens = body;
  for (var i = 0; i < body.length && at == null; i++) {
    final w = body[i];
    // "sau 20 phút", "20 phút nữa"
    if (w == 'sau' || w == 'trong') {
      final d = readDuration(body, i + 1);
      if (d != null) {
        at = now.add(d.duration);
        textTokens = [...body.sublist(0, i), ...body.sublist(i + 1 + d.length)];
        continue;
      }
    }
    final d = readDuration(body, i);
    if (d != null && i + d.length < body.length && body[i + d.length] == 'nữa') {
      at = now.add(d.duration);
      textTokens = [...body.sublist(0, i), ...body.sublist(i + d.length + 1)];
      continue;
    }
    // "lúc ba giờ chiều", "vào lúc 15 giờ", or a bare "ba giờ chiều"
    var j = i;
    if (w == 'lúc' || w == 'vào') {
      j = i + 1;
      if (w == 'vào' && j < body.length && body[j] == 'lúc') j++;
    }
    final c = readClockTime(body, j);
    if (c != null && (j > i || i > 0 || body.length == c.length)) {
      at = resolveClockTime(c, now, tomorrow: tomorrow);
      textTokens = [...body.sublist(0, i), ...body.sublist(j + c.length)];
    }
  }
  while (textTokens.isNotEmpty && const {'lúc', 'vào', 'nhé', 'nha', 'đi', 'với'}.contains(textTokens.last)) {
    textTokens = textTokens.sublist(0, textTokens.length - 1);
  }
  if (textTokens.isEmpty) return null;
  return AddReminder(sentence(textTokens), at);
}

Command? _screen(List<String> t) {
  if (hasAny(t, ['tắt màn', 'chế độ đêm', 'đi ngủ', 'chúc ngủ ngon'])) return const ScreenOff();
  if (hasAny(t, ['bật màn', 'mở màn', 'sáng màn'])) return const ScreenOn();
  return null;
}

/// "chia màn ba cột (lịch, giá vàng, hẹn giờ)", "mở ba cột", "về một cột", "về dải ngày". Checked before "về" alone
/// (go home) and before the timer rule, which would take "hẹn giờ" inside the list of columns.
Command? _layout(List<String> t) {
  final swap = _swapPanel(t);
  if (swap != null) return swap;
  if (hasAny(t, ['một cột', '1 cột', 'dải ngày', 'bỏ chia', 'gộp cột'])) return const SingleColumn();
  if (hasAny(t, ['chia màn', 'chia cột', 'ba cột', '3 cột', 'hai cột', '2 cột', 'nhiều cột'])) {
    final named = _panelsIn(t);
    return SplitColumns(named.length >= 2 ? named : null);
  }
  return null;
}

/// Words for each panel, longest first where they overlap ("tỷ giá" before "giá vàng" is read at "tỷ").
const _panelWords = <(List<String>, Panel)>[
  (['tỷ', 'giá'], Panel.fx),
  (['tỉ', 'giá'], Panel.fx),
  (['đô', 'la'], Panel.fx),
  (['ngoại', 'tệ'], Panel.fx),
  (['usd'], Panel.fx),
  (['đô'], Panel.fx),
  (['giá', 'vàng'], Panel.gold),
  (['vàng'], Panel.gold),
  (['lịch'], Panel.calendar),
  (['hẹn', 'giờ'], Panel.timer),
  (['đếm', 'ngược'], Panel.timer),
  (['bấm', 'giờ'], Panel.timer),
];

/// The panels named in [t], in the order said, each once.
List<Panel> _panelsIn(List<String> t) {
  final out = <Panel>[];
  var i = 0;
  while (i < t.length) {
    var step = 1;
    for (final (words, panel) in _panelWords) {
      if (i + words.length <= t.length && Iterable<int>.generate(words.length).every((k) => t[i + k] == words[k])) {
        if (!out.contains(panel)) out.add(panel);
        step = words.length;
        break;
      }
    }
    i += step;
  }
  return out;
}

/// "cột giữa" = 1, "cột trái"/"cột đầu"/"cột một" = 0, "cột phải"/"cột cuối" = -1 (the last), "cột hai" = 1, "cột ba"
/// = 2; "bên trái"/"bên phải" too. Null when no column is named. "ba cột" (how many) is not a position.
int? _columnIndex(List<String> t) {
  for (var k = 0; k < t.length; k++) {
    if (t[k] != 'cột' && t[k] != 'bên') continue;
    var i = k + 1;
    if (i < t.length && t[i] == 'thứ') i++;
    if (i >= t.length) continue;
    final w = t[i];
    if (w == 'giữa') return 1;
    if (w == 'trái' || w == 'đầu') return 0;
    if (w == 'phải' || w == 'cuối') return -1;
    if (t[k] == 'cột') {
      if (w == 'nhất') return 0;
      final n = readNumber(t, i);
      if (n != null && n.value >= 1 && n.value <= StripLayout.maxColumns) return n.value - 1;
    }
  }
  return null;
}

/// "đổi cột giữa sang tỷ giá đô la", "chuyển cột phải thành giá vàng", "đổi vàng sang tỷ giá". The new panel follows
/// "sang"/"thành"/"bằng"; "đổi lịch họp sang thứ năm" names no panel there and is left to the other rules.
Command? _swapPanel(List<String> t) {
  if (!hasAny(t, ['đổi', 'chuyển', 'thay'])) return null;
  final cut = t.indexWhere((w) => w == 'sang' || w == 'thành' || w == 'bằng');
  if (cut < 0) return null;
  final to = _panelsIn(t.sublist(cut + 1));
  if (to.isEmpty) return null;
  final before = t.sublist(0, cut);
  final index = _columnIndex(before);
  final from = _panelsIn(before);
  if (index == null && from.isEmpty && !before.contains('cột')) return null;
  return SwapPanel(to.first, index: index, from: index == null ? from.firstOrNull : null);
}

/// "mở chart vàng" (Zipformer may write "chát"), "so với hôm qua thì sao", "báo anh khi vàng vượt 4.150 đô".
Command? _gold(List<String> t) {
  final gold = hasPhrase(t, 'vàng');
  if (gold && hasAny(t, ['báo', 'canh'])) {
    for (var i = 0; i < t.length; i++) {
      if (!const {'vượt', 'qua', 'quá', 'lên', 'tới', 'dưới', 'xuống'}.contains(t[i])) continue;
      var j = i + 1;
      while (j < t.length && const {'qua', 'quá', 'mức', 'ngưỡng', 'lên', 'tới', 'dưới', 'xuống'}.contains(t[j])) {
        j++;
      }
      final n = readNumber(t, j);
      if (n != null && n.value >= 1000) return SetGoldAlert(n.value.toDouble());
    }
  }
  if (hasAny(t, ['so với hôm qua', 'so hôm qua', 'hôm qua thì sao', 'hôm qua thế nào', 'hôm qua ra sao'])) {
    return const CompareGoldYesterday();
  }
  if (gold && hasAny(t, ['chart', 'chát', 'chạt', 'biểu đồ', 'đồ thị', 'giá vàng', 'mở vàng', 'xem vàng'])) {
    return const ShowGold();
  }
  return null;
}

const _weekdays = {
  'thứ hai': DateTime.monday, 'thứ 2': DateTime.monday,
  'thứ ba': DateTime.tuesday, 'thứ 3': DateTime.tuesday,
  'thứ tư': DateTime.wednesday, 'thứ 4': DateTime.wednesday,
  'thứ năm': DateTime.thursday, 'thứ 5': DateTime.thursday,
  'thứ sáu': DateTime.friday, 'thứ 6': DateTime.friday,
  'thứ bảy': DateTime.saturday, 'thứ 7': DateTime.saturday,
  'chủ nhật': DateTime.sunday,
};

/// "tuần này có gì", "thứ năm rảnh lúc nào", "mở lịch tháng này", "còn mấy ngày tới hạn gửi báo giá",
/// "sáu giờ chiều nay có họp không".
Command? _calendar(List<String> t, DateTime now) {
  final busy = _busyAt(t, now);
  if (busy != null) return busy;
  if (hasAny(t, ['còn mấy ngày', 'còn bao nhiêu ngày', 'mấy ngày nữa', 'bao nhiêu ngày nữa'])) {
    for (final w in const ['tới hạn', 'đến hạn', 'tới', 'đến', 'hạn']) {
      final k = indexOfPhrase(t, w.split(' '));
      if (k < 0) continue;
      final q = t.sublist(k + w.split(' ').length).where((x) => !const {'nữa', 'là', 'không', 'vậy', 'ạ'}.contains(x));
      if (q.isNotEmpty) return DaysUntil(q.join(' '));
    }
    return null;
  }
  if (hasAny(t, ['rảnh', 'trống lịch', 'lúc nào trống'])) {
    for (final MapEntry(:key, :value) in _weekdays.entries) {
      if (hasPhrase(t, key)) return FreeSlots(value);
    }
  }
  if (hasAny(t, ['lịch tháng', 'tháng này'])) return const ShowMonth();
  if (hasAny(t, ['tuần này', 'lịch tuần', 'cả tuần'])) return const ShowWeek();
  return null;
}

const _busyWords = [
  'có họp', 'có cuộc họp', 'có lịch', 'có hẹn', 'có bận', 'bận không', 'rảnh không', 'có rảnh', 'có gì', 'có việc',
];

/// "sáu giờ chiều nay có họp không", "3 giờ có lịch gì không", "mai 9 giờ có bận không". Not with a weekday ("thứ năm
/// rảnh lúc nào" is [FreeSlots]) and not for timers ("có hẹn giờ nào không" has no clock time).
Command? _busyAt(List<String> t, DateTime now) {
  if (!hasAny(t, _busyWords)) return null;
  if (_weekdays.keys.any((k) => hasPhrase(t, k))) return null;
  for (var i = 0; i < t.length; i++) {
    final c = readClockTime(t, i);
    if (c == null) continue;
    final tomorrow = hasAny(t, ['ngày mai', 'sáng mai', 'chiều mai', 'tối mai', 'mai']);
    var at = resolveClockTime(c, now, tomorrow: tomorrow);
    // "sáu giờ sáng nay" asked in the afternoon is about this morning, not tomorrow's.
    if (!tomorrow && hasPhrase(t, 'nay') && !sameDay(at, now)) at = at.subtract(const Duration(days: 1));
    return BusyAt(at);
  }
  return null;
}

Command? _unsupported(List<String> t) {
  if (t.first == 'dời' || t.first == 'rời' || hasAny(t, ['đổi lịch', 'hủy cuộc họp', 'hủy họp'])) {
    return const NotSupported('Dời hay hủy lịch họp chưa làm được trên bản demo');
  }
  return null;
}

const _timerWords = ['hẹn giờ', 'đặt giờ', 'bấm giờ', 'đếm giờ', 'đếm ngược', 'tập trung'];
const _stopVerbs = ['hủy', 'dừng', 'tắt', 'bỏ', 'xóa', 'ngừng', 'kết thúc'];

/// Zipformer often hears "hẹn giờ" as "hiện giờ", which also means "right now" ("hiện giờ là mấy giờ"). It is read as
/// the timer word only where "now" makes no sense: right before a duration or right after a stop verb.
const _misheardTimer = ['hiện', 'giờ'];

Command? _cancelTimer(List<String> t) {
  if (hasAny(t, _stopVerbs) && hasAny(t, _timerWords)) return const CancelTimer();
  final k = indexOfPhrase(t, _misheardTimer);
  return k > 0 && _stopVerbs.contains(t[k - 1]) ? const CancelTimer() : null;
}

Command? _timeLeft(List<String> t) {
  if (hasAny(t, ['bao nhiêu phút', 'bao lâu nữa', 'mấy phút nữa', 'còn bao lâu', 'còn bao nhiêu'])) {
    return const TimeLeft();
  }
  return null;
}

Command? _startTimer(List<String> t) {
  if (!hasAny(t, _timerWords)) {
    final k = indexOfPhrase(t, _misheardTimer);
    final d = k < 0 ? null : readDuration(t, k + _misheardTimer.length);
    return d != null && d.duration > Duration.zero ? StartTimer(d.duration, focus: false) : null;
  }
  final focus = hasPhrase(t, 'tập trung');
  for (var i = 0; i < t.length; i++) {
    final d = readDuration(t, i);
    if (d != null && d.duration > Duration.zero) return StartTimer(d.duration, focus: focus);
  }
  // "bắt đầu tập trung": a classic 25-minute session.
  return focus ? const StartTimer(Duration(minutes: 25), focus: true) : null;
}

Command? _simple(List<String> t) {
  // "hôm nay thế nào" only at the start: "thời tiết hôm nay thế nào" is about the weather.
  if (hasAny(t, ['tổng kết', 'hôm nay làm được gì']) || indexOfPhrase(t, const ['hôm', 'nay', 'thế', 'nào']) == 0) {
    return const ShowRecap();
  }
  if (hasAny(t, ['ngày mai', 'mai có gì', 'lịch mai'])) return const ShowTomorrow();
  if (hasAny(t, ['tiếp theo', 'kế tiếp', 'sắp tới', 'họp tới', 'việc tới']) ||
      (hasPhrase(t, 'lịch') && hasAny(t, ['có gì', 'thế nào', 'ra sao']))) {
    return const WhatsNext();
  }
  if (hasAny(t, ['mấy giờ rồi', 'là mấy giờ', 'bây giờ mấy giờ'])) return const WhatTime();
  if (hasAny(t, ['về màn chính', 'quay lại', 'trở về', 'về trang chính', 'màn chính']) ||
      (t.length <= 2 && (t.first == 'thôi' || t.first == 'đóng' || t.first == 'về'))) {
    return const GoHome();
  }
  return null;
}
