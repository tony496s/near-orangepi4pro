/// The local Vietnamese model hears English dev words as Vietnamese syllables. Measured on the board (17/11, the
/// zipformer-vi model, macOS voice "Linh"): "loading" → "leo đình", "login" → "lou in", "spinner" → "skin nêu",
/// "ship" → "syp", "testflight" → "test levis", "backend" → "barcade", and "hey near" → "hai nia".
library;

const _fixes = <List<String>, String>{
  ['leo', 'đình']: 'loading',
  ['lô', 'đinh']: 'loading',
  ['lô', 'đình']: 'loading',
  ['lâu', 'đinh']: 'loading',
  ['lâu', 'đình']: 'loading',
  ['lo', 'đinh']: 'loading',
  ['lốt', 'đinh']: 'loading',
  ['lou', 'in']: 'login',
  ['lo', 'gin']: 'login',
  ['lốc', 'in']: 'login',
  ['lóc', 'in']: 'login',
  ['log', 'in']: 'login',
  ['skin', 'nêu']: 'spinner',
  ['spin', 'nơ']: 'spinner',
  ['xờ', 'pin', 'nơ']: 'spinner',
  ['barcade']: 'backend',
  ['bác', 'en']: 'backend',
  ['bắc', 'en']: 'backend',
  ['back', 'end']: 'backend',
  ['syp']: 'ship',
  ['síp']: 'ship',
  ['xíp']: 'ship',
  ['shíp']: 'ship',
  ['test', 'levis']: 'testflight',
  ['test', 'flai']: 'testflight',
  ['tét', 'flai']: 'testflight',
  ['test', 'flight']: 'testflight',
  ['tét']: 'test',
};

const _wake = [
  ['hey', 'near'],
  ['hai', 'nia'],
  ['hây', 'nia'],
  ['hay', 'nia'],
  ['hây', 'nịa'],
];

/// [tokens] (lower case, from `tokenize`) with a leading wake phrase dropped and misheard dev words put back.
List<String> fixDevWords(List<String> tokens) {
  var t = tokens;
  for (final w in _wake) {
    if (t.length >= w.length && _at(t, 0, w)) {
      t = t.sublist(w.length);
      break;
    }
  }
  final out = <String>[];
  var i = 0;
  outer:
  while (i < t.length) {
    for (final MapEntry(key: from, value: to) in _fixes.entries) {
      if (_at(t, i, from)) {
        out.add(to);
        i += from.length;
        continue outer;
      }
    }
    out.add(t[i++]);
  }
  return out;
}

bool _at(List<String> t, int i, List<String> phrase) {
  if (i + phrase.length > t.length) return false;
  for (var k = 0; k < phrase.length; k++) {
    if (t[i + k] != phrase[k]) return false;
  }
  return true;
}
