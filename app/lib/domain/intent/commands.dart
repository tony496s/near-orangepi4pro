/// What a spoken (or typed) sentence asks the strip to do.
sealed class Command {
  const Command();
}

/// "hẹn giờ 25 phút để tập trung". [focus] sessions hide reminders until they end.
final class StartTimer extends Command {
  const StartTimer(this.duration, {required this.focus});
  final Duration duration;
  final bool focus;

  @override
  bool operator ==(Object other) => other is StartTimer && other.duration == duration && other.focus == focus;
  @override
  int get hashCode => Object.hash(duration, focus);
  @override
  String toString() => 'StartTimer($duration, focus: $focus)';
}

final class CancelTimer extends Command {
  const CancelTimer();
}

/// "còn bao nhiêu phút nữa"
final class TimeLeft extends Command {
  const TimeLeft();
}

/// "tiếp theo là gì", "lịch chiều nay có gì"
final class WhatsNext extends Command {
  const WhatsNext();
}

/// "bây giờ là mấy giờ"
final class WhatTime extends Command {
  const WhatTime();
}

/// "ghi lại: mua sữa và trứng trên đường về"
final class AddNote extends Command {
  const AddNote(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is AddNote && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'AddNote($text)';
}

/// "nhắc anh gọi cho chị Lan lúc ba giờ chiều". [at] is null when no time was said: the strip asks for one.
final class AddReminder extends Command {
  const AddReminder(this.text, this.at);
  final String text;
  final DateTime? at;

  @override
  bool operator ==(Object other) => other is AddReminder && other.text == text && other.at == at;
  @override
  int get hashCode => Object.hash(text, at);
  @override
  String toString() => 'AddReminder($text, $at)';
}

final class ShowRecap extends Command {
  const ShowRecap();
}

final class ShowTomorrow extends Command {
  const ShowTomorrow();
}

/// "tắt màn": night mode now, until "bật màn" or the morning.
final class ScreenOff extends Command {
  const ScreenOff();
}

final class ScreenOn extends Command {
  const ScreenOn();
}

final class GoHome extends Command {
  const GoHome();
}

/// Understood, but not something the strip can do yet ("dời cuộc họp …"). [what] is shown to the user.
final class NotSupported extends Command {
  const NotSupported(this.what);
  final String what;
}
