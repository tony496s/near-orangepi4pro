import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/data/fx_source.dart';
import 'package:near_app/data/price_source.dart';

void main() {
  const source = SampleFxSource();
  final day = DateTime(2026, 11, 16);

  List<double> prices(PriceSeries s) => [for (final p in s.points) p.price];

  test('31 daily points at midnight, ending today', () {
    final s = source.usdVnd(day.add(const Duration(hours: 13, minutes: 41)));
    expect(s.points, hasLength(31));
    expect(s.points.last.at, day);
    expect(s.points.first.at, DateTime(2026, 10, 17));
    for (var i = 1; i < s.points.length; i++) {
      final prev = s.points[i - 1].at;
      expect(s.points[i].at, DateTime(prev.year, prev.month, prev.day + 1), reason: 'point $i is the next day');
      expect(s.points[i].at.hour, 0);
      expect(s.points[i].at.minute, 0);
    }
  });

  test('the days run across month and year ends', () {
    final s = source.usdVnd(DateTime(2027, 1, 5, 8));
    expect(s.points.first.at, DateTime(2026, 12, 6));
    expect(s.points.last.at, DateTime(2027, 1, 5));
    expect(s.points.map((p) => p.at).toSet(), hasLength(31), reason: 'no day twice');
  });

  test('the same day always gives the same rates, whatever the time; another day differs', () {
    final early = source.usdVnd(day.add(const Duration(minutes: 1)));
    final late = source.usdVnd(day.add(const Duration(hours: 23, minutes: 59)));
    expect(prices(late), prices(early));
    expect(prices(source.usdVnd(day.add(const Duration(days: 1)))), isNot(prices(early)));
    expect(prices(source.usdVnd(day.subtract(const Duration(days: 1)))), isNot(prices(early)));
  });

  test('rates are whole đồng in 26.300..26.399, end near 26.385 and move a few đồng a day', () {
    var steps = 0;
    var stepSum = 0.0;
    for (var d = 0; d < 400; d++) {
      final s = source.usdVnd(DateTime(2026, 1, 1 + d, 9));
      for (final p in s.points) {
        expect(p.price, p.price.roundToDouble(), reason: 'whole đồng on ${p.at}');
        expect(p.price, inInclusiveRange(SampleFxSource.floor, SampleFxSource.ceiling), reason: '${p.at}');
      }
      expect(s.last, inInclusiveRange(26380, 26390), reason: 'today ends near 26.385');
      expect(s.open, inInclusiveRange(26300, 26320), reason: '30 days ago starts near 26.310');
      for (var i = 1; i < s.points.length; i++) {
        final step = (s.points[i].price - s.points[i - 1].price).abs();
        expect(step, lessThanOrEqualTo(20), reason: 'no jump on ${s.points[i].at}');
        stepSum += step;
        steps++;
      }
    }
    expect(stepSum / steps, inInclusiveRange(2, 8), reason: 'daily steps of a few đồng, like the demo');
  });

  test('sinceYesterday is today minus the day before', () {
    final s = source.usdVnd(day);
    expect(s.sinceYesterday, s.last - s.points[s.points.length - 2].price);

    final rising = PriceSeries([
      PricePoint(DateTime(2026, 11, 14), 26300),
      PricePoint(DateTime(2026, 11, 15), 26373),
      PricePoint(DateTime(2026, 11, 16), 26385),
    ]);
    expect(rising.sinceYesterday, 12);
    expect(rising.change, 85, reason: 'change is over the whole series');

    final falling = PriceSeries([PricePoint(DateTime(2026, 11, 15), 26390), PricePoint(DateTime(2026, 11, 16), 26385)]);
    expect(falling.sinceYesterday, -5);

    expect(PriceSeries([PricePoint(day, 26385)]).sinceYesterday, 0, reason: 'a single point');
  });
}
