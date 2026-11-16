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
      expect((VoiceEvent.decode('{"ev":"wake","keyword":"HEY_NEAR"}') as VoiceWake).keyword, 'HEY_NEAR');
    });

    test('ready and final carry the engines', () {
      final r = VoiceEvent.decode('{"ev":"ready","model":"m","stt":"deepgram","tts":false,"wake":"sherpa-kws"}') as VoiceReady;
      expect((r.model, r.stt, r.wake), ('m', 'deepgram', 'sherpa-kws'));
      final old = VoiceEvent.decode('{"ev":"ready","model":"m"}') as VoiceReady;
      expect((old.stt, old.wake), ('', 'off'), reason: 'a service from before the fields');
      expect(old.langs, ['vi'], reason: 'a service from before langs: Vietnamese only');
      final both = VoiceEvent.decode('{"ev":"ready","model":"m","langs":["vi","en"]}') as VoiceReady;
      expect(both.langs, ['vi', 'en']);
      expect((VoiceEvent.decode('{"ev":"ready","model":"m","langs":[]}') as VoiceReady).langs, ['vi']);
      final f = VoiceEvent.decode('{"ev":"final","id":"l1","text":"x","engine":"deepgram"}') as VoiceFinal;
      expect(f.engine, 'deepgram');
      expect((VoiceEvent.decode('{"ev":"final","id":"l1","text":"x"}') as VoiceFinal).engine, '');
    });

    test('malformed or unknown lines are ignored', () {
      expect(VoiceEvent.decode('not json'), isNull);
      expect(VoiceEvent.decode('[1,2]'), isNull);
      expect(VoiceEvent.decode('{"ev":"say_done"}'), isNull, reason: 'future event');
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
      client.listen('l2', lang: 'en');
      client.finish();
      client.chime('soft');
      client.setWake(false);
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current), {'cmd': 'listen', 'id': 'l1', 'lang': 'vi'});
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current), {'cmd': 'listen', 'id': 'l2', 'lang': 'en'});
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current), {'cmd': 'finish'});
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current), {'cmd': 'chime', 'name': 'soft'});
      expect(await incoming.moveNext(), isTrue);
      expect(jsonDecode(incoming.current), {'cmd': 'wake', 'on': false});

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
