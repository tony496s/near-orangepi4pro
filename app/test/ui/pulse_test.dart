import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/ui/widgets/pulse.dart';

void main() {
  test('opacity goes 1 → 0.55 → 1 over a period', () {
    expect(pulseOpacity(Duration.zero), 1);
    expect(pulseOpacity(const Duration(milliseconds: 600)), closeTo(.775, 1e-9));
    expect(pulseOpacity(const Duration(milliseconds: 1200)), closeTo(.55, 1e-9));
    expect(pulseOpacity(const Duration(milliseconds: 1800)), closeTo(.775, 1e-9));
    expect(pulseOpacity(const Duration(milliseconds: 2400)), 1);
    expect(pulseOpacity(const Duration(milliseconds: 3600)), closeTo(.55, 1e-9), reason: 'it repeats');
  });

  testWidgets('steps on a timer and asks for no frame in between (a 60 Hz pulse cost ~40% of a core)', (tester) async {
    double opacity() => tester.widget<Opacity>(find.byType(Opacity)).opacity;
    await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: Pulse(child: Text('Tập trung sâu'))));
    expect(opacity(), 1);
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'idle between steps');

    await tester.pump(Pulse.step);
    expect(opacity(), closeTo(pulseOpacity(Pulse.step), 1e-9));
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pump(Pulse.step * 14); // 15 steps = 1.2 s, the bottom of the pulse
    expect(opacity(), closeTo(.55, 1e-9));

    await tester.pumpWidget(const SizedBox());
    // flutter_test fails the test if the periodic timer outlived the widget.
  });
}
