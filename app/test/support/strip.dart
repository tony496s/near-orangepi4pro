import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/app/app_controller.dart';
import 'package:near_app/core/clock.dart';
import 'package:near_app/data/calendar_source.dart';
import 'package:near_app/data/network_probe.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/ui/strip_app.dart';
import 'package:near_app/voice/voice_client.dart';

import 'fakes.dart';

/// A strip on a 1480x320 view, with a fake clock, the sample calendar and a fake voice service.
class StripHarness {
  StripHarness(this.tester, this.clock, this.voice, this.c);
  final WidgetTester tester;
  final FakeClock clock;
  final FakeVoice voice;
  final AppController c;

  /// [columns]: start on the three-column home screen, as a first start does. Most tests are about the day strip, so
  /// they start on one column.
  static Future<StripHarness> pump(WidgetTester tester,
      {required DateTime at, DateTime? launchedAt, bool columns = false, NetworkProbe? network}) async {
    tester.view.physicalSize = const Size(1480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = FakeClock(at);
    final voice = FakeVoice();
    final c = AppController(
      clock: clock,
      store: tempStore(),
      // With the clock, as on the board: the sample 1:1 moves to 14:00 twenty minutes after launch.
      calendar: SampleCalendarSource(launchedAt: launchedAt ?? DateTime(at.year, at.month, at.day, 6), clock: clock),
      voice: voice,
      heardHold: Duration.zero,
      log: (_) {},
      network: network,
    );
    await tester.runAsync(() => c.start(ticker: false));
    if (!columns) {
      c.run(const SingleColumn());
      c.flash = null; // the "đã lưu bố cục" note is for a spoken switch, not this setup
    }
    await tester.pumpWidget(StripApp(controller: c));
    await tester.pump(const Duration(seconds: 1));
    return StripHarness(tester, clock, voice, c);
  }

  /// Advances the clock second by second like the app's ticker, then lets transitions finish.
  Future<void> run(Duration d) async {
    for (var s = 0; s < d.inSeconds; s++) {
      clock.advance(const Duration(seconds: 1));
      c.tick();
    }
    await settle();
  }

  Future<void> settle() async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> say(String text) async {
    c.talk();
    final id = voice.sent.last.split(' ').last;
    voice.emit(VoiceFinal(id, text));
    await settle();
  }
}
