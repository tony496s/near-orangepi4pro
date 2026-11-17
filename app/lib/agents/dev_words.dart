/// The local Vietnamese model hears English dev words as Vietnamese syllables. Measured on the board (17/11, the
/// zipformer-vi model, macOS voice "Linh"): "loading" → "leo đình", "login" → "lou in", "spinner" → "skin nêu",
/// "ship" → "syp", "testflight" → "test levis", "backend" → "barcade", and "hey near" → "hai nia".
library;

import 'console_model.dart';

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

/// Words a machine phrase must follow: "… trên laptop", "… ở server".
const _on = {'trên', 'ở'};

/// Machines a spoken task can name, as the board's model heard them (17/11, synthetic voice): "trên macbook" →
/// "trên ma quốc" or "trên macbook", "trên máy mac" → "trên máy móc", "trên máy chủ" → "trên mái chủ"; "laptop" and
/// "server" come through as is. Two-word phrases first, so "mac book" is not taken as "mac".
const _machines = <(List<String>, Machine)>[
  (['mac', 'book'], Machine.macbook),
  (['mác', 'búc'], Machine.macbook),
  (['mắc', 'búc'], Machine.macbook),
  (['ma', 'quốc'], Machine.macbook),
  (['máy', 'mac'], Machine.macbook),
  (['máy', 'móc'], Machine.macbook),
  (['lap', 'top'], Machine.macbook),
  (['máy', 'chủ'], Machine.server),
  (['mái', 'chủ'], Machine.server),
  (['sơ', 'vơ'], Machine.server),
  (['macbook'], Machine.macbook),
  (['laptop'], Machine.macbook),
  (['mac'], Machine.macbook),
  (['server'], Machine.server),
];

/// The machine a spoken task names ("… trên laptop", "… ở server") and [tokens] (lower case, after [fixDevWords])
/// without the phrase and the "trên" / "ở" before it; no machine: `null` and [tokens] as they are.
///
/// A machine counts only right after "trên" or "ở": "máy móc" is a real word, and a bare "server" or "laptop" is more
/// likely what the task is about ("thêm cache cho server") than where it should run.
({Machine? machine, List<String> rest}) machineIn(List<String> tokens) {
  for (var i = 1; i < tokens.length; i++) {
    if (!_on.contains(tokens[i - 1])) continue;
    for (final (phrase, machine) in _machines) {
      if (_at(tokens, i, phrase)) {
        return (machine: machine, rest: [...tokens.sublist(0, i - 1), ...tokens.sublist(i + phrase.length)]);
      }
    }
  }
  return (machine: null, rest: tokens);
}

bool _at(List<String> t, int i, List<String> phrase) {
  if (i + phrase.length > t.length) return false;
  for (var k = 0; k < phrase.length; k++) {
    if (t[i + k] != phrase[k]) return false;
  }
  return true;
}
