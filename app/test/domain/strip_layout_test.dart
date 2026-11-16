import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/strip_layout.dart';

void main() {
  test('first start is three columns: calendar, gold, timer', () {
    expect(StripLayout.initial.split, isTrue);
    expect(StripLayout.initial.panels, [Panel.calendar, Panel.gold, Panel.timer]);
  });

  test('one column keeps the column set for next time', () {
    final one = StripLayout.initial.single();
    expect(one.split, isFalse);
    expect(one.panels, StripLayout.initial.panels);
    expect(one.columns(), StripLayout.initial);
  });

  test('columns(named) takes the named set when it has two or more, at most three', () {
    final one = StripLayout.initial.single();
    expect(one.columns(const [Panel.calendar, Panel.fx]), const StripLayout([Panel.calendar, Panel.fx]));
    expect(one.columns(const [Panel.fx]), StripLayout.initial, reason: 'one name: the remembered set');
    expect(one.columns(const []), StripLayout.initial);
    expect(one.columns(Panel.values).panels.length, StripLayout.maxColumns);
  });

  test('withPanel: replace a column, or swap when the panel is already shown', () {
    const l = StripLayout.initial; // calendar, gold, timer
    expect(l.withPanel(1, Panel.fx), const StripLayout([Panel.calendar, Panel.fx, Panel.timer]));
    expect(l.withPanel(-1, Panel.fx), const StripLayout([Panel.calendar, Panel.gold, Panel.fx]), reason: 'from the right');
    expect(l.withPanel(0, Panel.timer), const StripLayout([Panel.timer, Panel.gold, Panel.calendar]), reason: 'no twice');
    expect(l.withPanel(1, Panel.gold), l);
    expect(l.single().withPanel(1, Panel.fx).split, isTrue, reason: 'changing a column shows the columns');
    expect(l.withPanel(5, Panel.fx), l, reason: 'no such column');
  });

  test('JSON round trip', () {
    for (final l in [
      StripLayout.initial,
      StripLayout.initial.single(),
      const StripLayout([Panel.gold, Panel.timer]),
      const StripLayout([Panel.calendar, Panel.fx, Panel.timer]),
    ]) {
      expect(StripLayout.fromJson(l.toJson()), l);
    }
  });

  test('bad JSON falls back without losing the split choice', () {
    expect(StripLayout.fromJson({}), StripLayout.initial, reason: 'nothing saved yet');
    expect(StripLayout.fromJson({'panels': ['gold', 'weather', 'timer'], 'split': false}),
        const StripLayout([Panel.gold, Panel.timer], split: false), reason: 'unknown panel dropped');
    expect(StripLayout.fromJson({'panels': ['gold'], 'split': false}), StripLayout.initial.single(),
        reason: 'fewer than two panels: the initial set');
    expect(StripLayout.fromJson({'panels': 'x'}), StripLayout.initial);
  });
}
