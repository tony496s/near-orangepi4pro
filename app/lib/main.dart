import 'dart:io';

import 'package:flutter/widgets.dart';

import 'agents/agent_console.dart';
import 'agents/console_app.dart';
import 'app/app_controller.dart';
import 'core/clock.dart';
import 'data/calendar_source.dart';
import 'data/local_store.dart';
import 'data/network_probe.dart';
import 'ui/strip_app.dart';
import 'voice/voice_client.dart';

/// Near desk strip. Environment:
/// - NEAR_DATA_DIR: where state.json lives (default ~/.local/share/near);
/// - NEAR_VOICE_PORT: port of the near-voice service on localhost (default 8781);
/// - NEAR_DEMO_MOVE_AFTER: minutes after launch when the sample 1:1 (14:30) moves to 14:00 (default 20; "off": only
///   on SIGUSR2);
/// - NEAR_MODE=agents: the agent console demo instead of the day strip (see [runAgentConsole]).
///
/// Demo of "lịch đổi" (scenario 6, 13:05): `kill -USR2 <flutter-pi pid>` moves the 1:1 now and fetches the calendar,
/// so the strip shows "LỊCH VỪA ĐỔI · 14:30 → 14:00" and the old slot as a dashed ghost at once (only before 14:00).
/// Demo of "mất mạng": take the board off Wi-Fi; the probe (TCP to 1.1.1.1:53 every 30 s) shows the card within
/// about 40 s, and it goes when the network is back.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  void log(String s) => stdout.writeln('near: $s');
  if (Platform.environment['NEAR_MODE'] == 'agents') return runAgentConsole(log);
  const clock = SystemClock();
  final moveEnv = Platform.environment['NEAR_DEMO_MOVE_AFTER'];
  final sample = SampleCalendarSource(
    launchedAt: clock.now(),
    clock: clock,
    moveAfter: moveEnv == 'off'
        ? null
        : Duration(minutes: int.tryParse(moveEnv ?? '') ?? SampleCalendarSource.defaultMoveAfter.inMinutes),
  );
  final voice = VoiceClient(port: int.tryParse(Platform.environment['NEAR_VOICE_PORT'] ?? '') ?? 8781, log: log)..start();
  final controller = AppController(
    clock: clock,
    store: LocalStore.atDefaultPath(log: log),
    calendar: sample,
    voice: voice,
    log: log,
    network: const SocketProbe(),
  );
  await controller.start();
  // Lets a shell on the board start listening without touching the screen (tests and measurements):
  // kill -USR1 <flutter-pi pid>.
  if (Platform.isLinux) ProcessSignal.sigusr1.watch().listen((_) => controller.talk());
  // Demo: the calendar changes now (kill -USR2 <flutter-pi pid>).
  if (Platform.isLinux) {
    ProcessSignal.sigusr2.watch().listen((_) {
      sample.moveNow();
      controller.refreshCalendar();
    });
  }
  runApp(StripApp(controller: controller));
}

/// The agent console demo: agents running in the box, given work by voice. On the board, `kill -USR1 <pid>` listens
/// (like a tap on the "giao việc" slot) and `kill -USR2 <pid>` starts the demo over. NEAR_AGENTS_AUTOPLAY=1 starts it
/// playing by itself (a double tap on the left rail toggles that too).
void runAgentConsole(void Function(String) log) {
  final voice = VoiceClient(port: int.tryParse(Platform.environment['NEAR_VOICE_PORT'] ?? '') ?? 8781, log: log)..start();
  final console = AgentConsole(voice: voice, log: log)..start();
  if (Platform.environment['NEAR_AGENTS_AUTOPLAY'] == '1') console.setAutoplay(true);
  if (Platform.isLinux) {
    ProcessSignal.sigusr1.watch().listen((_) => console.talk());
    ProcessSignal.sigusr2.watch().listen((_) => console.reset());
  }
  runApp(ConsoleApp(console: console));
}
