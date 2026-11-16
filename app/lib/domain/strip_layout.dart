/// What the strip shows as its home screen: the day strip (one column) or 2-3 side-by-side panels.
///
/// The column set is remembered even while the strip is on one column, so "chia màn ba cột" brings back the same set.
enum Panel { calendar, gold, timer }

class StripLayout {
  const StripLayout(this.panels, {this.split = true});

  /// First start: three columns (calendar, gold, timer).
  static const initial = StripLayout([Panel.calendar, Panel.gold, Panel.timer]);

  final List<Panel> panels;

  /// True: the columns are the home screen. False: the day strip is.
  final bool split;

  StripLayout single() => StripLayout(panels, split: false);
  StripLayout columns() => StripLayout(panels, split: true);

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
