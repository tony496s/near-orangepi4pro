import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/intent/vi_text.dart';
import 'package:near_app/domain/intent/vi_time.dart';

Duration? dur(String s) => readDuration(tokenize(s), 0)?.duration;

DateTime? at(String s, DateTime now, {bool tomorrow = false}) {
  final c = readClockTime(tokenize(s), 0);
  return c == null ? null : resolveClockTime(c, now, tomorrow: tomorrow);
}

void main() {
  group('durations', () {
    test('minutes, seconds, hours', () {
      expect(dur('mười lăm phút'), const Duration(minutes: 15));
      expect(dur('30 giây'), const Duration(seconds: 30));
      expect(dur('một tiếng'), const Duration(hours: 1));
      expect(dur('2 giờ'), const Duration(hours: 2));
    });

    test('halves and mixed units', () {
      expect(dur('nửa tiếng'), const Duration(minutes: 30));
      expect(dur('một tiếng rưỡi'), const Duration(minutes: 90));
      expect(dur('hai giờ mười phút'), const Duration(minutes: 130));
    });

    test('a number without a unit is not a duration', () {
      expect(dur('mười lăm'), isNull);
      expect(dur('mười lăm người'), isNull);
    });
  });

  group('clock times', () {
    final afternoon = DateTime(2026, 11, 16, 14, 12);

    test('part of day picks the hour', () {
      expect(at('ba giờ chiều', afternoon), DateTime(2026, 11, 16, 15));
      expect(at('tám giờ rưỡi sáng', afternoon), DateTime(2026, 11, 17, 8, 30), reason: 'already past today');
      expect(at('một giờ trưa', DateTime(2026, 11, 16, 9)), DateTime(2026, 11, 16, 13));
      expect(at('mười giờ tối', afternoon), DateTime(2026, 11, 16, 22));
    });

    test('minutes, rưỡi and kém', () {
      expect(at('mười giờ mười lăm', DateTime(2026, 11, 16, 9)), DateTime(2026, 11, 16, 10, 15));
      expect(at('ba giờ kém mười lăm', afternoon), DateTime(2026, 11, 16, 14, 45));
      expect(at('15 giờ 30', afternoon), DateTime(2026, 11, 16, 15, 30));
      expect(at('15:30', afternoon), DateTime(2026, 11, 16, 15, 30));
    });

    test('without a part of day: next waking-hours occurrence', () {
      // STT dropped "chiều" in E4: "lúc ba giờ" at 14:12 must still mean 15:00.
      expect(at('ba giờ', afternoon), DateTime(2026, 11, 16, 15));
      expect(at('tám giờ', afternoon), DateTime(2026, 11, 16, 20));
      expect(at('tám giờ', DateTime(2026, 11, 16, 7)), DateTime(2026, 11, 16, 8));
      expect(at('một giờ', DateTime(2026, 11, 16, 23)), DateTime(2026, 11, 17, 13));
    });

    test('tomorrow is forced when asked', () {
      expect(at('ba giờ chiều', afternoon, tomorrow: true), DateTime(2026, 11, 17, 15));
      expect(at('tám giờ', afternoon, tomorrow: true), DateTime(2026, 11, 17, 8));
    });

    test('not a clock time', () {
      expect(at('ba người', afternoon), isNull);
      expect(at('năm mươi giờ', afternoon), isNull);
    });
  });
}
