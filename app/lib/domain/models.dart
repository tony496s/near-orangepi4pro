/// Plain data for the strip. JSON shapes here are what `LocalStore` writes; keep them backward compatible.
library;

enum EventKind { meeting, focus, meal, personal, deadline }

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.kind = EventKind.meeting,
    this.place,
    this.people,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final EventKind kind;
  final String? place;
  final int? people;

  Duration get length => end.difference(start);

  bool isOngoing(DateTime now) => !now.isBefore(start) && now.isBefore(end);

  /// "Phòng 3 · 4 người"
  String get details => [?place, if (people != null) '$people người'].join(' · ');
}

/// The one countdown that can run at a time: a focus session or a plain timer.
class ActiveTimer {
  const ActiveTimer({required this.startedAt, required this.duration, required this.focus});

  final DateTime startedAt;
  final Duration duration;
  final bool focus;

  DateTime get endsAt => startedAt.add(duration);

  Duration remaining(DateTime now) {
    final r = endsAt.difference(now);
    return r.isNegative ? Duration.zero : r;
  }

  bool isDone(DateTime now) => !now.isBefore(endsAt);

  /// 0 at the start, 1 when done.
  double progress(DateTime now) {
    if (duration.inMilliseconds <= 0) return 1;
    return (now.difference(startedAt).inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  Map<String, Object?> toJson() =>
      {'startedAt': startedAt.toIso8601String(), 'seconds': duration.inSeconds, 'focus': focus};

  static ActiveTimer fromJson(Map<String, Object?> j) => ActiveTimer(
        startedAt: DateTime.parse(j['startedAt'] as String),
        duration: Duration(seconds: (j['seconds'] as num).toInt()),
        focus: j['focus'] as bool? ?? false,
      );
}

/// A finished (or cancelled) focus session, for the daily recap.
class FocusSession {
  const FocusSession({required this.start, required this.end, required this.completed});

  final DateTime start;
  final DateTime end;
  final bool completed;

  Duration get length => end.difference(start);

  Map<String, Object?> toJson() =>
      {'start': start.toIso8601String(), 'end': end.toIso8601String(), 'completed': completed};

  static FocusSession fromJson(Map<String, Object?> j) => FocusSession(
        start: DateTime.parse(j['start'] as String),
        end: DateTime.parse(j['end'] as String),
        completed: j['completed'] as bool? ?? false,
      );
}

class Note {
  const Note({required this.id, required this.text, required this.createdAt, this.doneAt});

  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime? doneAt;

  bool get done => doneAt != null;

  Note copyWith({DateTime? Function()? doneAt}) =>
      Note(id: id, text: text, createdAt: createdAt, doneAt: doneAt == null ? this.doneAt : doneAt());

  Map<String, Object?> toJson() =>
      {'id': id, 'text': text, 'createdAt': createdAt.toIso8601String(), 'doneAt': doneAt?.toIso8601String()};

  static Note fromJson(Map<String, Object?> j) => Note(
        id: j['id'] as String,
        text: j['text'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        doneAt: j['doneAt'] == null ? null : DateTime.parse(j['doneAt'] as String),
      );
}

class Reminder {
  const Reminder({
    required this.id,
    required this.text,
    required this.at,
    required this.createdAt,
    this.firedAt,
    this.doneAt,
  });

  final String id;
  final String text;

  /// When it is due. Snoozing moves this.
  final DateTime at;
  final DateTime createdAt;

  /// When the alert was shown for the current [at]; null until then.
  final DateTime? firedAt;
  final DateTime? doneAt;

  bool get done => doneAt != null;

  bool isDue(DateTime now) => !done && firedAt == null && !now.isBefore(at);

  Reminder copyWith({DateTime? at, DateTime? Function()? firedAt, DateTime? Function()? doneAt}) => Reminder(
        id: id,
        text: text,
        at: at ?? this.at,
        createdAt: createdAt,
        firedAt: firedAt == null ? this.firedAt : firedAt(),
        doneAt: doneAt == null ? this.doneAt : doneAt(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        'at': at.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'firedAt': firedAt?.toIso8601String(),
        'doneAt': doneAt?.toIso8601String(),
      };

  static Reminder fromJson(Map<String, Object?> j) => Reminder(
        id: j['id'] as String,
        text: j['text'] as String,
        at: DateTime.parse(j['at'] as String),
        createdAt: DateTime.parse(j['createdAt'] as String),
        firedAt: j['firedAt'] == null ? null : DateTime.parse(j['firedAt'] as String),
        doneAt: j['doneAt'] == null ? null : DateTime.parse(j['doneAt'] as String),
      );
}
