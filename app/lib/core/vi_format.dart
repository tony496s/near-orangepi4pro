/// Vietnamese date and time strings for the strip.
library;

const _weekdays = ['Thứ Hai', 'Thứ Ba', 'Thứ Tư', 'Thứ Năm', 'Thứ Sáu', 'Thứ Bảy', 'Chủ Nhật'];
const _months = [
  'một', 'hai', 'ba', 'tư', 'năm', 'sáu', 'bảy', 'tám', 'chín', 'mười', 'mười một', 'mười hai', //
];

String two(int n) => n.toString().padLeft(2, '0');

/// "08:52"
String hhmm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

/// "Thứ Hai"
String weekdayName(DateTime t) => _weekdays[t.weekday - 1];

/// "THỨ HAI · 16 THÁNG MƯỜI MỘT"
String dateLine(DateTime t) => '${weekdayName(t)} · ${t.day} tháng ${_months[t.month - 1]}'.toUpperCase();

/// "Thứ Hai 16/11"
String shortDate(DateTime t) => '${weekdayName(t)} ${t.day}/${t.month}';

/// "1 giờ 10 phút", "8 phút", "2 giờ", "0 phút". Rounds to the minute, never negative.
String durationVi(Duration d) {
  final minutes = d.isNegative ? 0 : (d.inSeconds / 60).round();
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m phút';
  if (m == 0) return '$h giờ';
  return '$h giờ $m phút';
}

/// "24:59" for a countdown; hours are folded into minutes. Never negative.
String mmss(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  return '${two(s ~/ 60)}:${two(s % 60)}';
}

/// First letter upper-cased, the rest untouched.
String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Vietnamese number: '.' between thousands, ',' before decimals ("4.146,2").
String viNumber(double v, {int decimals = 1}) {
  final fixed = v.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final whole = parts[0];
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write('.');
    grouped.write(whole[i]);
  }
  final sign = v < 0 && double.parse(fixed) != 0 ? '-' : '';
  return parts.length > 1 ? '$sign$grouped,${parts[1]}' : '$sign$grouped';
}

/// A gold price as spoken in the strip: "4.150" for a round number, else "4.146,4".
String viPrice(double v) => v == v.roundToDouble() ? viNumber(v, decimals: 0) : viNumber(v);

/// The next [weekday] (DateTime.monday..sunday) from [t]'s day, today included, at midnight.
DateTime weekdayAhead(DateTime t, int weekday) {
  final day = DateTime(t.year, t.month, t.day);
  return day.add(Duration(days: (weekday - t.weekday + 7) % 7));
}
