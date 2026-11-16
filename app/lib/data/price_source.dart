/// Gold price for the strip. The demo uses [SamplePriceSource]; v1 swaps in a real feed behind [PriceSource].
class PricePoint {
  const PricePoint(this.at, this.price);
  final DateTime at;
  final double price;
}

/// One day of prices from 00:00 up to now, oldest first. Never empty.
class PriceSeries {
  PriceSeries(this.points) : assert(points.isNotEmpty);
  final List<PricePoint> points;

  double get open => points.first.price;
  double get last => points.last.price;
  double get high => points.map((p) => p.price).reduce((a, b) => a > b ? a : b);
  double get low => points.map((p) => p.price).reduce((a, b) => a < b ? a : b);
  double get change => last - open;
  double get changePct => change / open * 100;
}

abstract interface class PriceSource {
  /// World gold, USD per ounce, for the day of [now], every 5 minutes up to [now].
  PriceSeries goldToday(DateTime now);
}

/// Made-up prices that look plausible at any hour: a random walk seeded by the date, so the same day always gives the
/// same curve and the chart only grows as time passes. Not a real price (the screen says so).
class SamplePriceSource implements PriceSource {
  const SamplePriceSource();

  static const step = Duration(minutes: 5);

  @override
  PriceSeries goldToday(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final n = now.difference(day).inMinutes ~/ step.inMinutes;
    var seed = now.year * 10000 + now.month * 100 + now.day;
    double next() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    var price = 4100 + next() * 40;
    final points = <PricePoint>[];
    for (var i = 0; i <= n; i++) {
      points.add(PricePoint(day.add(step * i), (price * 10).roundToDouble() / 10));
      price += (next() - .45) * 1.6; // a slow upward drift with noise, about +30 over a day
    }
    return PriceSeries(points);
  }
}
