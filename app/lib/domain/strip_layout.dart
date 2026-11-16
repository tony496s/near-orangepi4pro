/// What the strip shows as its home screen: the day strip (one column) or 2-3 side-by-side panels.
///
/// The column set is remembered even while the strip is on one column, so "chia màn ba cột" brings back the same set.
enum Panel { calendar, gold, timer, fx }

class StripLayout {
  const StripLayout(this.panels, {this.split = true});

  /// First start: three columns (calendar, gold, timer).
  static const initial = StripLayout([Panel.calendar, Panel.gold, Panel.timer]);

  final List<Panel> panels;

  /// True: the columns are the home screen. False: the day strip is.
  final bool split;

  StripLayout single() => StripLayout(panels, split: false);
  /// Most columns that fit the strip.
  static const maxColumns = 3;

  /// The columns as home; [named] replaces the set when it has at least two ("chia màn ba cột: lịch, giá vàng, hẹn
  /// giờ"), otherwise the remembered set comes back.
  StripLayout columns([List<Panel>? named]) {
    final set = named != null && named.length >= 2 ? named.take(maxColumns).toList(growable: false) : panels;
    return StripLayout(set, split: true);
  }

  /// Column [index] (negative counts from the right) shows [p], on the columns. If [p] is already in another column the
  /// two swap places, so a panel never shows twice. An index out of range changes nothing but the split.
  StripLayout withPanel(int index, Panel p) {
    final i = index < 0 ? panels.length + index : index;
    if (i < 0 || i >= panels.length) return columns();
    final next = [...panels];
    final j = next.indexOf(p);
    if (j >= 0) next[j] = next[i];
    next[i] = p;
    return StripLayout(List.unmodifiable(next), split: true);
  }

  Map<String, Object?> toJson() => {
    'panels': [for (final p in panels) p.name],
    'split': split,
  };

  /// Unknown panel names are dropped; fewer than two panels left means the initial set.
  static StripLayout fromJson(Map<String, Object?> j) {
    final raw = j['panels'];
    final names = raw is List ? raw.whereType<String>() : const <String>[];
    final panels = [for (final n in names) ...Panel.values.where((p) => p.name == n)];
    return StripLayout(panels.length < 2 ? initial.panels : panels, split: j['split'] != false);
  }

  @override
  bool operator ==(Object other) =>
      other is StripLayout &&
      other.split == split &&
      other.panels.length == panels.length &&
      Iterable.generate(panels.length).every((i) => other.panels[i] == panels[i]);

  @override
  int get hashCode => Object.hash(split, Object.hashAll(panels));
}
