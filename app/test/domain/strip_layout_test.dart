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

  test('JSON round trip', () {
    for (final l in [StripLayout.initial, StripLayout.initial.single(), const StripLayout([Panel.gold, Panel.timer])]) {
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
