import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Messages from the near-voice service (see docs/superpowers/specs, section 6).
sealed class VoiceEvent {
  const VoiceEvent();

  /// Parses one JSON line; null for anything unknown or malformed (the protocol may grow).
  static VoiceEvent? decode(String line) {
    final Object? j;
    try {
      j = jsonDecode(line);
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    final id = j['id'] as String? ?? '';
    switch (j['ev']) {
      case 'ready':
        return VoiceReady(j['model'] as String? ?? '');
      case 'listening':
        return VoiceListening(id);
      case 'level':
        final db = j['db'];
        return db is num ? VoiceLevel(db.toDouble()) : null;
      case 'processing':
        return VoiceProcessing(id);
      case 'final':
        return VoiceFinal(id, j['text'] as String? ?? '',
            sttMs: (j['stt_ms'] as num?)?.toInt() ?? 0, audioMs: (j['audio_ms'] as num?)?.toInt() ?? 0);
      case 'timeout':
        return VoiceTimeout(id);
      case 'error':
        return VoiceError(j['msg'] as String? ?? '');
    }
    return null;
  }
}

final class VoiceReady extends VoiceEvent {
  const VoiceReady(this.model);
  final String model;
}

final class VoiceListening extends VoiceEvent {
  const VoiceListening(this.id);
  final String id;
}

/// Input level for the listening bars, about 10 per second while listening.
final class VoiceLevel extends VoiceEvent {
  const VoiceLevel(this.db);
  final double db;
}

/// End of speech detected; speech-to-text is running.
final class VoiceProcessing extends VoiceEvent {
  const VoiceProcessing(this.id);
  final String id;
}

final class VoiceFinal extends VoiceEvent {
  const VoiceFinal(this.id, this.text, {this.sttMs = 0, this.audioMs = 0});
  final String id;
  final String text;
  final int sttMs;
  final int audioMs;
}

/// Nobody spoke within the service's no-speech timeout.
final class VoiceTimeout extends VoiceEvent {
  const VoiceTimeout(this.id);
  final String id;
}

final class VoiceError extends VoiceEvent {
  const VoiceError(this.message);
  final String message;
}

/// The connection to the service dropped (it may be restarting).
final class VoiceDisconnected extends VoiceEvent {
  const VoiceDisconnected();
}

/// What the app needs from the voice service; [VoiceClient] is the real one, tests use a fake.
abstract interface class VoiceLink {
  Stream<VoiceEvent> get events;

  /// Connected and the model is loaded.
  bool get ready;

  void listen(String id);

  void cancel();

  /// Plays a short sound: "soft" or "alert".
  void chime(String name);
}

/// TCP client for near-voice on localhost. Reconnects every [retry] while the service is down.
class VoiceClient implements VoiceLink {
  VoiceClient({this.host = '127.0.0.1', this.port = 8781, this.retry = const Duration(seconds: 2), this.log = _noLog});

  final String host;
  final int port;
  final Duration retry;
  final void Function(String) log;

  static void _noLog(String _) {}

  final _events = StreamController<VoiceEvent>.broadcast();
  Socket? _socket;
  bool _ready = false;
  bool _closed = false;
  Timer? _retryTimer;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  bool get ready => _ready && _socket != null;

  /// Starts connecting; returns at once. Safe to call once.
  void start() => _connect();

  Future<void> _connect() async {
    if (_closed) return;
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      if (_closed) {
        s.destroy();
        return;
      }
      _socket = s;
      s.setOption(SocketOption.tcpNoDelay, true);
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
        _onLine,
        onError: (Object e) => _drop('socket error: $e'),
        onDone: () => _drop('closed by service'),
        cancelOnError: true,
      );
    } catch (e) {
      _scheduleRetry();
    }
  }

  void _onLine(String line) {
    final ev = VoiceEvent.decode(line);
    if (ev == null) return;
    if (ev is VoiceReady) _ready = true;
    _events.add(ev);
  }

  void _drop(String why) {
    log('voice: $why');
    _socket?.destroy();
    _socket = null;
    final wasReady = _ready;
    _ready = false;
    if (wasReady || !_closed) _events.add(const VoiceDisconnected());
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retry, _connect);
  }

  void _send(Map<String, Object?> msg) {
    final s = _socket;
    if (s == null) return;
    try {
      s.write('${jsonEncode(msg)}\n');
    } catch (e) {
      _drop('write failed: $e');
    }
  }

  @override
  void listen(String id) => _send({'cmd': 'listen', 'id': id});

  @override
  void cancel() => _send({'cmd': 'cancel'});

  @override
  void chime(String name) => _send({'cmd': 'chime', 'name': name});

  /// Stops reconnecting and closes the event stream. Does not wait for listeners to drain it: a paused listener
  /// would otherwise keep close() pending forever.
  Future<void> close() async {
    _closed = true;
    _retryTimer?.cancel();
    _socket?.destroy();
    _socket = null;
    unawaited(_events.close());
  }
}
