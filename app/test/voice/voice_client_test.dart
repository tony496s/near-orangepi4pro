import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/voice/voice_client.dart';

void main() {
  group('decode', () {
    test('every event of the protocol', () {
      expect((VoiceEvent.decode('{"ev":"ready","model":"zipformer-vi-30m"}') as VoiceReady).model, 'zipformer-vi-30m');
      expect((VoiceEvent.decode('{"ev":"listening","id":"l1"}') as VoiceListening).id, 'l1');
      expect((VoiceEvent.decode('{"ev":"level","db":-31.5}') as VoiceLevel).db, -31.5);
      expect((VoiceEvent.decode('{"ev":"processing","id":"l1"}') as VoiceProcessing).id, 'l1');
      final f = VoiceEvent.decode('{"ev":"final","id":"l1","text":"HỦY HẸN GIỜ","stt_ms":170,"audio_ms":1800}') as VoiceFinal;
      expect((f.id, f.text, f.sttMs, f.audioMs), ('l1', 'HỦY HẸN GIỜ', 170, 1800));
      expect((VoiceEvent.decode('{"ev":"timeout","id":"l2"}') as VoiceTimeout).id, 'l2');
      expect((VoiceEvent.decode('{"ev":"error","msg":"mic busy"}') as VoiceError).message, 'mic busy');
    });

    test('malformed or unknown lines are ignored', () {
      expect(VoiceEvent.decode('not json'), isNull);
      expect(VoiceEvent.decode('[1,2]'), isNull);
      expect(VoiceEvent.decode('{"ev":"wake"}'), isNull, reason: 'future event');
      expect(VoiceEvent.decode('{"ev":"level","db":"loud"}'), isNull);
    });
  });

  group('connection', () {
    late ServerSocket server;
    late StreamController<Socket> accepted;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      accepted = StreamController<Socket>();
      server.listen(accepted.add);
    });

    tearDown(() async {
      await server.close();
    });

    Stream<String> lines(Socket s) => s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());

    test('ready, commands out, events in, then reconnect after the service restarts', () async {
      final client = VoiceClient(port: server.port, retry: const Duration(milliseconds: 50));
      final events = StreamIterator(client.events);
      client.start();
      final queue = StreamIterator(accepted.stream);

      expect(await queue.moveNext(), isTrue);
      final s1 = queue.current;
      final incoming = StreamIterator(lines(s1));
      s1.write('{"ev":"ready","model":"m"}\n');
      expect(await events.moveNext(), isTrue);
      expect(events.current, isA<VoiceReady>());
      expect(client.ready, isTrue);

      client.listen('l1');
      client.finish();
      client.chime('soft');
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current), {'cmd': 'listen', 'id': 'l1'});
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current), {'cmd': 'finish'});
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current), {'cmd': 'chime', 'name': 'soft'});

      // Two events in one TCP write are split by line.
      s1.write('{"ev":"processing","id":"l1"}\n{"ev":"final","id":"l1","text":"x"}\n');
      expect(await events.moveNext(), isTrue);
      expect(events.current, isA<VoiceProcessing>());
      expect(await events.moveNext(), isTrue);
      expect((events.current as VoiceFinal).text, 'x');

      s1.destroy();
      expect(await events.moveNext(), isTrue);
      expect(events.current, isA<VoiceDisconnected>());
      expect(client.ready, isFalse);

      expect(await queue.moveNext().timeout(const Duration(seconds: 2)), isTrue, reason: 'client reconnects');
      queue.current.write('{"ev":"ready","model":"m"}\n');
      expect(await events.moveNext(), isTrue);
      expect(client.ready, isTrue);
      await client.close();
    });

    test('commands while disconnected are dropped, not thrown', () async {
      final port = server.port;
      await server.close();
      final client = VoiceClient(port: port, retry: const Duration(seconds: 10));
      client.start();
      client.listen('l1');
      client.cancel();
      expect(client.ready, isFalse);
      await client.close();
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0); // for tearDown
    });
  });
}
