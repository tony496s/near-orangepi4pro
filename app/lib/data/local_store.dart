import '../domain/gold_alert.dart';
import '../domain/strip_layout.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/clock.dart';
import '../domain/models.dart';

/// Everything the strip must remember across reboots.
class StoredState {
  StoredState({
    List<Note>? notes,
    List<Reminder>? reminders,
    this.timer,
    List<FocusSession>? sessions,
    this.lastRecapDay,
    this.voiceLang = 'vi',
    this.layout = StripLayout.initial,
    this.goldAlert,
    Map<String, DateTime>? doneEvents,
  })  : notes = notes ?? [],
        reminders = reminders ?? [],
        sessions = sessions ?? [],
        doneEvents = doneEvents ?? {};

  final List<Note> notes;
  final List<Reminder> reminders;
  ActiveTimer? timer;
  final List<FocusSession> sessions;

  /// "2026-11-16" once the automatic recap was shown that day.
  String? lastRecapDay;

  /// The VI/EN switch: the language voice commands are spoken in.
  String voiceLang;

  /// Home screen layout. Missing on first start, which gives the three columns.
  StripLayout layout;

  /// "báo anh khi vàng vượt …", kept until it fires and is closed, or replaced.
  GoldAlert? goldAlert;

  /// Calendar deadlines marked done ("xong việc gửi báo giá"): event id -> when.
  final Map<String, DateTime> doneEvents;

  Map<String, Object?> toJson() => {
        'version': 1,
        'notes': [for (final n in notes) n.toJson()],
        'reminders': [for (final r in reminders) r.toJson()],
        'timer': timer?.toJson(),
        'sessions': [for (final s in sessions) s.toJson()],
        'lastRecapDay': lastRecapDay,
        'voiceLang': voiceLang,
              'layout': layout.toJson(),
        'goldAlert': goldAlert?.toJson(),
        'doneEvents': {for (final e in doneEvents.entries) e.key: e.value.toIso8601String()},
      };

  static StoredState fromJson(Map<String, Object?> j) {
    List<Map<String, Object?>> list(String key) =>
        ((j[key] as List?) ?? const []).cast<Map<String, Object?>>();
    return StoredState(
      notes: list('notes').map(Note.fromJson).toList(),
      reminders: list('reminders').map(Reminder.fromJson).toList(),
      timer: j['timer'] == null ? null : ActiveTimer.fromJson((j['timer'] as Map).cast<String, Object?>()),
      sessions: list('sessions').map(FocusSession.fromJson).toList(),
      lastRecapDay: j['lastRecapDay'] as String?,
      voiceLang: j['voiceLang'] == 'en' ? 'en' : 'vi',
      layout: j['layout'] is Map ? StripLayout.fromJson((j['layout'] as Map).cast<String, Object?>()) : StripLayout.initial,
      goldAlert: GoldAlert.fromJson(j['goldAlert']),
      doneEvents: {
        if (j['doneEvents'] is Map)
          for (final e in (j['doneEvents'] as Map).entries)
            if (e.value is String && DateTime.tryParse(e.value as String) != null)
              '${e.key}': DateTime.parse(e.value as String),
      },
    );
  }

  /// Drops history the strip will never show again: focus sessions older than 14 days, reminders done more than 7
  /// days ago.
  void prune(DateTime now) {
    sessions.removeWhere((s) => now.difference(s.end) > const Duration(days: 14));
    reminders.removeWhere((r) => r.doneAt != null && now.difference(r.doneAt!) > const Duration(days: 7));
    doneEvents.removeWhere((_, at) => now.difference(at) > const Duration(days: 30));
  }
}

/// JSON file store. Writes go to a temporary file that is flushed to disk before it replaces the old one, because the
/// board's rootfs is mounted with `commit=600` (a plain write can be lost for up to 10 minutes on power loss).
class LocalStore {
  LocalStore(this.file, {this.log = _noLog});

  final File file;
  final void Function(String) log;
  Future<void> _pending = Future.value();

  static void _noLog(String _) {}

  /// Default location: `$NEAR_DATA_DIR/state.json`, else `~/.local/share/near/state.json`.
  static LocalStore atDefaultPath({void Function(String) log = _noLog}) {
    final env = Platform.environment;
    final dir = env['NEAR_DATA_DIR'] ?? '${env['HOME'] ?? '.'}/.local/share/near';
    return LocalStore(File('$dir/state.json'), log: log);
  }

  /// The saved state; empty if there is none. A file that cannot be read is moved aside to `state.json.bad` so the
  /// strip still starts.
  Future<StoredState> load() async {
    if (!await file.exists()) return StoredState();
    try {
      final j = jsonDecode(await file.readAsString());
      return StoredState.fromJson((j as Map).cast<String, Object?>());
    } catch (e) {
      final bad = File('${file.path}.bad');
      log('state file unreadable ($e), moved to ${bad.path}');
      try {
        await file.rename(bad.path);
      } catch (_) {}
      return StoredState();
    }
  }

  /// Completes when every save started so far has finished (successfully or not).
  Future<void> get idle => _pending;

  /// Saves [state]. Calls are serialized; the returned future completes when this save is on disk (or failed).
  Future<void> save(StoredState state) {
    final body = const JsonEncoder.withIndent(' ').convert(state.toJson());
    final next = _pending.then((_) => _write(body));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _write(String body) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeString(body);
      await raf.flush(); // fsync
    } finally {
      await raf.close();
    }
    await tmp.rename(file.path);
    if (Platform.isLinux) {
      // Make the rename itself durable (fsync of the directory). Best effort: coreutils `sync DIR`.
      try {
        await Process.run('sync', [file.parent.path]);
      } catch (_) {}
    }
  }
}

String dayKey(DateTime t) => dayOf(t).toIso8601String().substring(0, 10);
