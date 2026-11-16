import 'dart:math' as math;

import 'price_source.dart';

/// The US dollar in đồng for the strip ("đổi cột giữa sang tỷ giá đô la"). The demo uses [SampleFxSource]; v1 swaps
/// in a real bank feed behind [FxSource].
abstract interface class FxSource {
  /// The bank's sell rate (bán ra), đồng per dollar, one point per day at 00:00 for the 30 days before the day of
  /// [now] and that day itself (31 points, oldest first, ending today).
  PriceSeries usdVnd(DateTime now);
}

/// Change from one point to the one before, for a series of one point per day (like [FxSource.usdVnd]).
extension DailySeries on PriceSeries {
  /// Today's rate minus yesterday's; 0 for a single point.
  double get sinceYesterday => points.length < 2 ? 0 : last - points[points.length - 2].price;
}

/// Made-up rates that look plausible: a random walk seeded by the date (the same day always gives the same 31 points),
/// rising from about 26.310 to about 26.385 with daily steps of a few đồng, like scenario 5 of near-demo.html. Not a
/// real rate (the screen says so).
class SampleFxSource implements FxSource {
  const SampleFxSource();

  /// Days before today in the series (31 points in all).
  static const days = 30;

  /// The sample never leaves 26.300..26.399.
  static const floor = 26300.0;
  static const ceiling = 26399.0;

  /// Largest random step from one day to the next, before the walk is pinned to its two ends.
  static const _vol = 7.0;

  @override
  PriceSeries usdVnd(DateTime now) {
    var seed = (now.year * 10000 + now.month * 100 + now.day) ^ 0x2f6b; // not the gold walk's seed
    double next() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    final start = 26305 + next() * 10; // 30 days ago
    final end = 26380 + next() * 10; // today
    // A walk with steps of up to ±_vol, then tilted so it is 0 at both ends (a Brownian bridge, like the demo's).
    final walk = <double>[0];
    for (var k = 1; k <= days; k++) {
      walk.add(walk[k - 1] + (next() - .5) * 2 * _vol);
    }
    final noise = [for (var k = 0; k <= days; k++) walk[k] - walk[days] * k / days];
    double line(int k) => start + (end - start) * k / days;
    // Squeeze the noise (not clip it, which would flatten the line) so every day stays within floor..ceiling.
    var squeeze = 1.0;
    for (var k = 0; k <= days; k++) {
      final n = noise[k];
      final room = n > 0 ? ceiling - line(k) : line(k) - floor;
      if (n.abs() > room) squeeze = math.min(squeeze, room / n.abs());
    }
    return PriceSeries([
      for (var k = 0; k <= days; k++)
        PricePoint(DateTime(now.year, now.month, now.day - (days - k)), (line(k) + noise[k] * squeeze).roundToDouble()),
    ]);
  }
}
