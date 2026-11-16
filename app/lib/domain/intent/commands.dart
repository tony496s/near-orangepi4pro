import '../strip_layout.dart';

/// What a spoken (or typed) sentence asks the strip to do.
sealed class Command {
  const Command();
}

/// "hẹn giờ 10 phút để tập trung". [focus] sessions hide reminders until they end.
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

/// "chia màn ba cột": the columns become the home screen (the remembered set).
final class SplitColumns extends Command {
  const SplitColumns([this.panels]);

  /// The columns named in the sentence, in order; null or fewer than two: the remembered set.
  final List<Panel>? panels;

  @override
  bool operator ==(Object other) =>
      other is SplitColumns &&
      (identical(other.panels, panels) ||
          (other.panels != null &&
              panels != null &&
              other.panels!.length == panels!.length &&
              Iterable.generate(panels!.length).every((i) => other.panels![i] == panels![i])));

  @override
  int get hashCode => Object.hashAll(panels ?? const []);

  @override
  String toString() => 'SplitColumns($panels)';
}

/// "đổi cột giữa sang tỷ giá đô la": one column changes, the others stay. [index] (negative from the right) or the
/// column now showing [from]; neither: the middle one.
final class SwapPanel extends Command {
  const SwapPanel(this.to, {this.index, this.from});
  final Panel to;
  final int? index;
  final Panel? from;

  @override
  bool operator ==(Object other) => other is SwapPanel && other.to == to && other.index == index && other.from == from;

  @override
  int get hashCode => Object.hash(to, index, from);

  @override
  String toString() => 'SwapPanel($to, index: $index, from: $from)';
}

/// "về một cột": the day strip becomes the home screen; the column set is kept for next time.
final class SingleColumn extends Command {
  const SingleColumn();
}

/// "mở chart vàng": the full gold chart.
final class ShowGold extends Command {
  const ShowGold();
}

/// "so với hôm qua thì sao" (on the gold chart): yesterday's line on the same axis.
final class CompareGoldYesterday extends Command {
  const CompareGoldYesterday();
}

/// "báo anh khi vàng vượt 4.150 đô".
final class SetGoldAlert extends Command {
  const SetGoldAlert(this.price);
  final double price;

  @override
  bool operator ==(Object other) => other is SetGoldAlert && other.price == price;
  @override
  int get hashCode => price.hashCode;
}

/// "tuần này có gì".
final class ShowWeek extends Command {
  const ShowWeek();
}

/// "thứ năm rảnh lúc nào": [weekday] is DateTime.monday..sunday.
final class FreeSlots extends Command {
  const FreeSlots(this.weekday);
  final int weekday;

  @override
  bool operator ==(Object other) => other is FreeSlots && other.weekday == weekday;
  @override
  int get hashCode => weekday.hashCode;
}

/// "mở lịch tháng này".
final class ShowMonth extends Command {
  const ShowMonth();
}

/// "còn mấy ngày tới hạn gửi báo giá": [query] is matched against event titles.
final class DaysUntil extends Command {
  const DaysUntil(this.query);
  final String query;

  @override
  bool operator ==(Object other) => other is DaysUntil && other.query == query;
  @override
  int get hashCode => query.hashCode;
}

/// Understood, but not something the strip can do yet ("dời cuộc họp …"). [what] is shown to the user.
/// "sáu giờ chiều nay có họp không": what is on around [at] (that hour).
final class BusyAt extends Command {
  const BusyAt(this.at);
  final DateTime at;

  @override
  bool operator ==(Object other) => other is BusyAt && other.at == at;

  @override
  int get hashCode => at.hashCode;

  @override
  String toString() => 'BusyAt($at)';
}

final class NotSupported extends Command {
  const NotSupported(this.what);
  final String what;
}
