import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/data/network_probe.dart';

void main() {
  test('a reachable port is up, a closed one is down (no exception)', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((s) => s.destroy());
    expect(await SocketProbe(host: '127.0.0.1', port: server.port).check(), isTrue);
    final port = server.port;
    await server.close();
    expect(await SocketProbe(host: '127.0.0.1', port: port, timeout: const Duration(milliseconds: 300)).check(), isFalse);
  });
}
