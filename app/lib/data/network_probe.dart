import 'dart:io';

/// Tells whether the network is up. The app asks every 30 seconds; tests use a fake.
abstract interface class NetworkProbe {
  Future<bool> check();
}

/// A TCP connect to a public DNS server, with a short timeout. Cheap (no data sent) and async, so it never blocks the
/// UI thread.
class SocketProbe implements NetworkProbe {
  const SocketProbe({this.host = '1.1.1.1', this.port = 53, this.timeout = const Duration(seconds: 3)});

  final String host;
  final int port;
  final Duration timeout;

  @override
  Future<bool> check() async {
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
