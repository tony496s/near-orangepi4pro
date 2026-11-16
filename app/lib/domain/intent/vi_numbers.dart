/// Vietnamese numbers in words or digits: "mười lăm" = 15, "hai mươi mốt" = 21, "một trăm linh năm" = 105,
/// "bốn nghìn một trăm năm mươi" = 4150, "15" = 15.
library;

const _units = {
  'không': 0, 'một': 1, 'mốt': 1, 'hai': 2, 'ba': 3, 'bốn': 4, 'tư': 4, 'năm': 5, 'lăm': 5, 'sáu': 6, //
  'bảy': 7, 'bẩy': 7, 'tám': 8, 'chín': 9,
};

/// A number read at [start] of [tokens]: (value, tokens consumed), or null if no number starts there.
({int value, int length})? readNumber(List<String> tokens, int start) {
  if (start >= tokens.length) return null;
  final digits = int.tryParse(tokens[start]);
  if (digits != null) return (value: digits, length: 1);

  var total = 0;
  int? hundreds;
  int? tens;
  int? units;
  var afterLinh = false;
  var i = start;
  var any = false;

  int group() => (hundreds ?? 0) * 100 + (tens ?? 0) + (units ?? 0);

  while (i < tokens.length) {
    final t = tokens[i];
    final u = _units[t];
    if (u != null) {
      // "lăm" and "mốt" only follow a ten ("mười lăm", "hai mươi mốt"); "tư" alone would be ambiguous, but after a
      // ten it is 4 ("hai mươi tư").
      if (units != null) break;
      if ((t == 'lăm' || t == 'mốt') && tens == null) break;
      units = u;
    } else if (t == 'mười') {
      if (tens != null || units != null) break;
      tens = 10;
    } else if (t == 'mươi') {
      if (units == null || tens != null || units == 0) break;
      tens = units * 10;
      units = null;
    } else if (t == 'trăm') {
      if (tens != null || hundreds != null) break;
      hundreds = units ?? 1;
      units = null;
    } else if ((t == 'linh' || t == 'lẻ') && hundreds != null && tens == null && units == null && !afterLinh) {
      afterLinh = true;
    } else if (t == 'nghìn' || t == 'ngàn') {
      if (!any) break;
      total += (group() == 0 ? 1 : group()) * 1000;
      hundreds = null;
      tens = null;
      units = null;
      afterLinh = false;
    } else {
      break;
    }
    any = true;
    i++;
  }
  if (!any) return null;
  // A trailing "linh" without its unit is not part of the number.
  if (afterLinh && units == null) i--;
  return (value: total + group(), length: i - start);
}
