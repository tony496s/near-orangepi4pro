/// "báo anh khi vàng vượt 4.150 đô": fires once when the price crosses [threshold] in the direction it was set.
class GoldAlert {
  const GoldAlert({required this.threshold, required this.above, required this.setAt, this.firedAt});

  /// [above] is true when the price was below the threshold when it was set (so it fires on the way up).
  factory GoldAlert.at(double threshold, {required double price, required DateTime now}) =>
      GoldAlert(threshold: threshold, above: price < threshold, setAt: now);

  final double threshold;
  final bool above;
  final DateTime setAt;
  final DateTime? firedAt;

  bool get fired => firedAt != null;

  /// True when [price] is past the threshold and the alert has not fired yet.
  bool crossedBy(double price) => !fired && (above ? price >= threshold : price <= threshold);

  GoldAlert fire(DateTime t) => GoldAlert(threshold: threshold, above: above, setAt: setAt, firedAt: t);

  Map<String, Object?> toJson() =>
      {'threshold': threshold, 'above': above, 'setAt': setAt.toIso8601String(), 'firedAt': firedAt?.toIso8601String()};

  static GoldAlert? fromJson(Object? j) {
    if (j is! Map) return null;
    final threshold = j['threshold'], setAt = DateTime.tryParse('${j['setAt']}');
    if (threshold is! num || setAt == null) return null;
    return GoldAlert(
        threshold: threshold.toDouble(),
        above: j['above'] != false,
        setAt: setAt,
        firedAt: j['firedAt'] == null ? null : DateTime.tryParse('${j['firedAt']}'));
  }
}
