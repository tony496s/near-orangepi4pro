import 'commands.dart';
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
  if (hasAny(t, ['một cột', '1 cột', 'dải ngày', 'bỏ chia', 'gộp cột'])) return const SingleColumn();
  if (hasAny(t, ['chia màn', 'chia cột', 'ba cột', '3 cột', 'hai cột', '2 cột', 'nhiều cột'])) return const SplitColumns();
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
