import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/core/vi_format.dart';

void main() {
  final monday = DateTime(2026, 11, 16, 8, 52, 30);

  test('date line spells the month in words, upper case', () {
    expect(dateLine(monday), 'THỨ HAI · 16 THÁNG MƯỜI MỘT');
    expect(dateLine(DateTime(2026, 4, 5)), 'CHỦ NHẬT · 5 THÁNG TƯ');
  });

  test('short date and clock', () {
    expect(shortDate(monday), 'Thứ Hai 16/11');
    expect(hhmm(monday), '08:52');
  });

  test('durations round to the minute and never go negative', () {
    expect(durationVi(const Duration(minutes: 70)), '1 giờ 10 phút');
    expect(durationVi(const Duration(minutes: 8)), '8 phút');
    expect(durationVi(const Duration(hours: 2)), '2 giờ');
    expect(durationVi(const Duration(seconds: 89)), '1 phút');
    expect(durationVi(const Duration(minutes: -5)), '0 phút');
  });

  test('countdown folds hours into minutes', () {
    expect(mmss(const Duration(minutes: 24, seconds: 59)), '24:59');
    expect(mmss(const Duration(minutes: 90)), '90:00');
    expect(mmss(const Duration(seconds: -3)), '00:00');
  });

  test('clock helpers', () {
    expect(dayOf(monday), DateTime(2026, 11, 16));
    expect(sameDay(monday, DateTime(2026, 11, 16, 23, 59)), isTrue);
    expect(clockLooksValid(DateTime(1970, 1, 1)), isFalse, reason: 'board clock before NTP sync');
    expect(clockLooksValid(monday), isTrue);
    final c = FakeClock(monday)..advance(const Duration(minutes: 8));
    expect(c.now(), DateTime(2026, 11, 16, 9, 0, 30));
  });
}
