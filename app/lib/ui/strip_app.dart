import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../app/app_controller.dart';
import 'screens/alert.dart';
import 'screens/ambient.dart';
import 'screens/focus.dart';
import 'screens/night.dart';
import 'screens/recap.dart';
import 'screens/tomorrow.dart';
import 'theme.dart';
import 'widgets/buttons.dart';
import 'widgets/overlays.dart';

/// Root widget: picks the screen from the controller state and handles strip-wide gestures.
///
/// - mic button (top right) or a 0.4 s long press on anything that is not a button: talk;
/// - swipe up: tomorrow; swipe down: back;
/// - at night: a tap shows the clock for a moment.
class StripApp extends StatelessWidget {
  const StripApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => WidgetsApp(
        color: Ink.bezel,
        debugShowCheckedModeBanner: false,
        textStyle: ts(16),
        builder: (context, _) => ColoredBox(
          color: Ink.bezel,
          child: FittedBox(
            child: SizedBox(
              width: stripWidth,
              height: stripHeight,
              child: ClipRect(child: ListenableBuilder(listenable: controller, builder: (context, _) => _Strip(c: controller))),
            ),
          ),
        ),
      );
}

class _Strip extends StatelessWidget {
  const _Strip({required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final alert = c.alert;
    final night = c.night && alert == null;
    final Widget screen;
    final String key;
    if (alert != null) {
      screen = AlertScreen(c: c, alert: alert);
      key = 'alert-${alert.shownAt.microsecondsSinceEpoch}';
    } else if (night) {
      screen = NightScreen(c: c);
      key = 'night';
    } else {
      switch (c.screen) {
        case Screen.recap:
          screen = RecapScreen(c: c);
          key = 'recap';
        case Screen.tomorrow:
          screen = TomorrowScreen(c: c);
          key = 'tomorrow';
        case Screen.home:
          screen = c.focusing ? FocusScreen(c: c) : AmbientScreen(c: c);
          key = c.focusing ? 'focus' : 'ambient';
      }
    }
    final showMic = !night || c.peeking;
    return Listener(
      onPointerDown: (_) => c.touched(),
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 400)),
            (r) => r.onLongPress = c.talk,
          ),
          VerticalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
            VerticalDragGestureRecognizer.new,
            (r) => r.onEnd = (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -250) c.swipeUp();
              if (v > 250) c.swipeDown();
            },
          ),
          if (night)
            TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              TapGestureRecognizer.new,
              (r) => r.onTap = c.tapNight,
            ),
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                child: KeyedSubtree(key: ValueKey(key), child: screen),
              ),
            ),
            if (showMic && alert == null)
              Positioned(right: 0, top: 0, child: MicButton(ready: c.micReady, warning: c.saveFailing, dim: night, onTap: c.talk)),
            if (showMic && alert == null && c.englishAvailable)
              Positioned(
                  right: 0, top: micZoneHeight, child: LangSwitch(lang: c.voiceLang, dim: night, onTap: c.toggleVoiceLang)),
            if (c.askTime != null && c.listening == null)
              Positioned.fill(child: AskTimeOverlay(ask: c.askTime!, onAnswer: c.answerAskTime)),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: c.listening == null,
                child: AnimatedOpacity(
                  opacity: c.listening == null ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: c.listening == null ? const SizedBox.shrink() : ListeningOverlay(listening: c.listening!, onTap: c.tapOverlay),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
