import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/data/price_source.dart';

void main() {
  const source = SamplePriceSource();
  final day = DateTime(2026, 11, 16);

  test('one point every 5 minutes from midnight, plus a live point at now', () {
    final s = source.goldToday(day.add(const Duration(hours: 8, minutes: 3)));
    expect(s.points.first.at, day);
    expect(s.points[s.points.length - 2].at, day.add(const Duration(hours: 8)));
    expect(s.points.last.at, day.add(const Duration(hours: 8, minutes: 3)), reason: 'live point');
    expect(s.points, hasLength(8 * 12 + 2));
    expect(source.goldToday(day.add(const Duration(hours: 8))).points, hasLength(8 * 12 + 1), reason: 'on a step');
    expect(source.goldToday(day).points, hasLength(1), reason: 'never empty');
  });

  test('the live price moves a few dollars within minutes, so a close threshold gets crossed', () {
    final t0 = day.add(const Duration(hours: 10, minutes: 1));
    final prices = [for (var s = 0; s < 120; s += 5) source.goldToday(t0.add(Duration(seconds: s))).last];
    final spread = prices.reduce((a, b) => a > b ? a : b) - prices.reduce((a, b) => a < b ? a : b);
    expect(spread, greaterThan(3));
    expect(spread, lessThan(15));
  });

  test('the same day always gives the same curve, and it only grows with time', () {
    final morning = source.goldToday(day.add(const Duration(hours: 8)));
    final noon = source.goldToday(day.add(const Duration(hours: 12, minutes: 2)));
    expect([for (final p in noon.points.take(morning.points.length)) p.price], [for (final p in morning.points) p.price]);
    expect(source.goldToday(day.add(const Duration(hours: 8))).last, morning.last);
    expect(source.goldToday(day.add(const Duration(days: 1, hours: 8))).last, isNot(morning.last), reason: 'other day');
  });

  test('prices look like world gold and the summary numbers add up', () {
    final s = source.goldToday(day.add(const Duration(hours: 23, minutes: 59)));
    for (final p in s.points) {
      expect(p.price, inInclusiveRange(4000, 4300));
    }
    expect(s.high, greaterThanOrEqualTo(s.last));
    expect(s.low, lessThanOrEqualTo(s.open));
    expect(s.change, closeTo(s.last - s.open, 1e-9));
    expect(s.changePct, closeTo((s.last - s.open) / s.open * 100, 1e-9));
  });
}
