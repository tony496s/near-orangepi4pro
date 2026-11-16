import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app/app_controller.dart';
import 'core/clock.dart';
import 'data/calendar_source.dart';
import 'data/local_store.dart';
import 'ui/strip_app.dart';
import 'voice/voice_client.dart';

/// Near desk strip. Environment:
/// - NEAR_DATA_DIR: where state.json lives (default ~/.local/share/near);
/// - NEAR_VOICE_PORT: port of the near-voice service on localhost (default 8781).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  void log(String s) => stdout.writeln('near: $s');
  const clock = SystemClock();
  final voice = VoiceClient(port: int.tryParse(Platform.environment['NEAR_VOICE_PORT'] ?? '') ?? 8781, log: log)..start();
  final controller = AppController(
    clock: clock,
    store: LocalStore.atDefaultPath(log: log),
    calendar: SampleCalendarSource(launchedAt: clock.now()),
    voice: voice,
    log: log,
  );
  await controller.start();
  // Lets a shell on the board start listening without touching the screen (tests and measurements):
  // kill -USR1 <flutter-pi pid>.
  if (Platform.isLinux) ProcessSignal.sigusr1.watch().listen((_) => controller.talk());
  runApp(StripApp(controller: controller));
}
