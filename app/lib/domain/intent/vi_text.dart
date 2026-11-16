import '../../core/vi_format.dart';

/// Normalizes a transcript for matching: NFC-ish fixes for old/new tone placement, lower case, punctuation removed,
/// digit clock times split ("15:30" -> "15 giờ 30", "3h30" -> "3 giờ 30"), thousand separators dropped ("4.150" ->
/// "4150"), and a leading wake phrase removed. Zipformer output is upper case without punctuation, typed text is not.
List<String> tokenize(String text) {
  var s = text.toLowerCase();
  for (final MapEntry(:key, :value) in _toneFixes.entries) {
    s = s.replaceAll(key, value);
  }
  s = s.replaceAllMapped(RegExp(r'(\d{1,2})\s*[:h]\s*(\d{2})\b'), (m) => ' ${m[1]} giờ ${m[2]} ');
  s = s.replaceAllMapped(RegExp(r'(\d{1,2})h\b'), (m) => ' ${m[1]} giờ ');
  s = s.replaceAllMapped(RegExp(r'(\d)[.,](\d{3})\b'), (m) => '${m[1]}${m[2]}');
  s = s.replaceAll(RegExp(r'''[,.!?;:"“”'‘’()\[\]«»…\-–—]'''), ' ');
  final tokens = s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  return _dropWakePhrase(tokens);
}

const _toneFixes = {
  'huỷ': 'hủy',
  'xoá': 'xóa',
  'hoà': 'hòa',
  'thuỷ': 'thủy',
  'khoẻ': 'khỏe',
  'tuỳ': 'tùy',
};

const _wakePhrases = [
  ['hey', 'near'],
  ['hây', 'nia'],
  ['hay', 'nia'],
  ['near', 'ơi'],
];

List<String> _dropWakePhrase(List<String> tokens) {
  for (final p in _wakePhrases) {
    if (tokens.length >= p.length && List.generate(p.length, (i) => tokens[i] == p[i]).every((x) => x)) {
      return tokens.sublist(p.length);
    }
  }
  return tokens;
}

/// Index of the first occurrence of [phrase] in [tokens] at or after [from], or -1.
int indexOfPhrase(List<String> tokens, List<String> phrase, [int from = 0]) {
  for (var i = from; i + phrase.length <= tokens.length; i++) {
    var ok = true;
    for (var k = 0; k < phrase.length && ok; k++) {
      ok = tokens[i + k] == phrase[k];
    }
    if (ok) return i;
  }
  return -1;
}

bool hasPhrase(List<String> tokens, String phrase) => indexOfPhrase(tokens, phrase.split(' ')) >= 0;

bool hasAny(List<String> tokens, List<String> phrases) => phrases.any((p) => hasPhrase(tokens, p));

/// Tokens joined back into a sentence with the first letter capitalized.
String sentence(List<String> tokens) => capitalize(tokens.join(' '));
