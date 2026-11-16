/// Source of the current time. Everything time-based in the app reads a [Clock] instead of calling `DateTime.now()`, so
/// timers, reminders, recap and night mode can be tested without waiting.
abstract interface class Clock {
  DateTime now();
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// A clock that only moves when told to. For tests.
class FakeClock implements Clock {
  FakeClock(this._now);

  DateTime _now;

  @override
  DateTime now() => _now;

  void set(DateTime value) => _now = value;

  void advance(Duration by) => _now = _now.add(by);
}

/// The calendar day of [t] (midnight, local time).
DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// The board has no RTC battery: until NTP syncs, the system clock can be years off.
bool clockLooksValid(DateTime t) => t.year >= 2025;
