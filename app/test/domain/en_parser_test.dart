import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/intent/en_parser.dart';

void main() {
  final now = DateTime(2026, 11, 16, 14, 12);
  Command? p(String s) => parseEnglishCommand(s, now);

  group('real Deepgram nova-3 transcripts from the E4 set (phase0 E4b)', () {
    test('the ones that came out right', () {
      expect(p('Set a timer for ten minutes.'), const StartTimer(Duration(minutes: 10), focus: false));
      expect(p('Cancel the timer.'), isA<CancelTimer>());
    });

    test('misheard ones still parse into what was heard', () {
      // said: "stretch in forty five minutes", "thirty minutes"
      expect(p('Remind me to dress in forty minutes.'), AddReminder('Dress', now.add(const Duration(minutes: 40))));
      expect(p('Start a focus session for three minutes.'), const StartTimer(Duration(minutes: 3), focus: true));
    });

    test('nonsense is not understood', () {
      expect(p("It's a notch. Reveal the pool direct to me."), isNull);
      expect(p(''), isNull);
    });
  });

  group('timers and focus', () {
    test('durations in digits and words', () {
      expect(p('Set a timer for 25 minutes.'), const StartTimer(Duration(minutes: 25), focus: false));
      expect(p('Set a timer for forty five minutes'), const StartTimer(Duration(minutes: 45), focus: false));
      expect(p('Set a 10 minute timer'), const StartTimer(Duration(minutes: 10), focus: false));
      expect(p('Set a timer for 10min'), const StartTimer(Duration(minutes: 10), focus: false));
      expect(p('Timer for half an hour'), const StartTimer(Duration(minutes: 30), focus: false));
      expect(p('Set a timer for an hour and a half'), const StartTimer(Duration(minutes: 90), focus: false));
      expect(p('Set a timer for 1 hour and 15 minutes'), const StartTimer(Duration(minutes: 75), focus: false));
      expect(p('Count down 90 seconds'), const StartTimer(Duration(seconds: 90), focus: false));
    });

    test('focus sessions', () {
      expect(p('Start a focus session for 30 minutes.'), const StartTimer(Duration(minutes: 30), focus: true));
      expect(p('Focus for an hour'), const StartTimer(Duration(hours: 1), focus: true));
      expect(p('Start focusing'), const StartTimer(Duration(minutes: 25), focus: true));
    });

    test('a timer word without a duration is not a timer', () {
      expect(p('Set a timer'), isNull);
    });

    test('stop, cancel, time left', () {
      expect(p('Stop the timer'), isA<CancelTimer>());
      expect(p('End the focus session'), isA<CancelTimer>());
      expect(p('Stop focusing'), isA<CancelTimer>());
      expect(p('How much time is left?'), isA<TimeLeft>());
      expect(p('How many minutes left?'), isA<TimeLeft>());
    });
  });

  group('notes', () {
    test('the prefix goes, the rest is the note with its case kept', () {
      expect(p('Add a note: buy milk and eggs on the way home.'), const AddNote('Buy milk and eggs on the way home'));
      expect(p('Take a note that Lan called'), const AddNote('Lan called'));
      expect(p('Note to self, call the bank'), const AddNote('Call the bank'));
      expect(p('Write down review the pull request tonight'), const AddNote('Review the pull request tonight'));
    });

    test('a note is checked first: its text may hold other commands', () {
      expect(
        p('Add a note: turn off the screen in the meeting room'),
        const AddNote('Turn off the screen in the meeting room'),
      );
    });

    test('a prefix alone is no note', () {
      expect(p('Add a note'), isNull);
    });
  });

  group('reminders', () {
    test('at a clock time', () {
      expect(p('Remind me to call Lan at 3 PM.'), AddReminder('Call Lan', DateTime(2026, 11, 16, 15)));
      expect(p('Remind me to call Lan at 3:30 p.m.'), AddReminder('Call Lan', DateTime(2026, 11, 16, 15, 30)));
      expect(
        p('Remind me at 8 tonight to take out the trash'),
        AddReminder('Take out the trash', DateTime(2026, 11, 16, 20)),
      );
      expect(
        p('Remind me to send the invoice at half past four'),
        AddReminder('Send the invoice', DateTime(2026, 11, 16, 16, 30)),
      );
      expect(p('Remind me to stand up at quarter to five'), AddReminder('Stand up', DateTime(2026, 11, 16, 16, 45)));
    });

    test('a bare hour after "at" is the next sensible one, as in Vietnamese', () {
      expect(p('Remind me to call the client at 3'), AddReminder('Call the client', DateTime(2026, 11, 16, 15)));
    });

    test('noon already passed today means tomorrow', () {
      expect(p('Remind me to call mom at noon'), AddReminder('Call mom', DateTime(2026, 11, 17, 12)));
    });

    test('after a duration', () {
      expect(p('Remind me in 20 minutes to stretch'), AddReminder('Stretch', now.add(const Duration(minutes: 20))));
      expect(
        p('Remind me to stretch 20 minutes from now'),
        AddReminder('Stretch', now.add(const Duration(minutes: 20))),
      );
      expect(
        p('Remind me in an hour to check the oven'),
        AddReminder('Check the oven', now.add(const Duration(hours: 1))),
      );
    });

    test('tomorrow', () {
      expect(
        p('Remind me tomorrow at 9 to send the report'),
        AddReminder('Send the report', DateTime(2026, 11, 17, 9)),
      );
      expect(
        p('Remind me to water the plants tomorrow afternoon'),
        AddReminder('Water the plants', DateTime(2026, 11, 17, 15)),
      );
      expect(p('Remind me to pay rent tomorrow'), AddReminder('Pay rent', DateTime(2026, 11, 17, 9)));
    });

    test('without a time, as the Vietnamese parser allows', () {
      expect(p('Remind me to water the plants'), const AddReminder('Water the plants', null));
    });

    test('"remind" must lead the sentence', () {
      expect(p('Add a note: remind Lan about the invoice'), const AddNote('Remind Lan about the invoice'));
      expect(p('Remind me'), isNull);
    });
  });

  group('screen, calendar and the rest', () {
    test('screen', () {
      expect(p('Turn off the screen.'), isA<ScreenOff>());
      expect(p('Screen off'), isA<ScreenOff>());
      expect(p('Good night'), isA<ScreenOff>());
      expect(p('Turn the screen on'), isA<ScreenOn>());
    });

    test('moving or cancelling a meeting is not supported, and is not "cancel the timer"', () {
      expect(p('Move my meeting to 4 PM'), isA<NotSupported>());
      expect(p('Cancel the meeting'), isA<NotSupported>());
    });

    test('questions', () {
      expect(p("What's next?"), isA<WhatsNext>());
      expect(p("What's my next meeting?"), isA<WhatsNext>());
      expect(p("What's coming up?"), isA<WhatsNext>());
      expect(p('What time is it?'), isA<WhatTime>());
      expect(p("What's on tomorrow?"), isA<ShowTomorrow>());
      expect(p('How was today?'), isA<ShowRecap>());
      expect(p('Go back'), isA<GoHome>());
    });

    test('a wake word left at the start is dropped', () {
      expect(p('Hey Near, what is next?'), isA<WhatsNext>());
      expect(p('Hey, Near. Set a timer for 5 minutes.'), const StartTimer(Duration(minutes: 5), focus: false));
    });

    test('Vietnamese words in English mode are not understood (and do not crash)', () {
      expect(p('Hẹn giờ mười lăm phút'), isNull);
    });
  });

  group('enTokenize', () {
    test('punctuation, times, contractions', () {
      expect(enTokenize('Set a timer for 10min.'), ['Set', 'a', 'timer', 'for', '10', 'min']);
      expect(enTokenize('at 3:30 p.m.'), ['at', '3', '30', 'pm']);
      expect(enTokenize('at 3PM'), ['at', '3', 'PM']);
      expect(enTokenize("What's twenty-five"), ['What', 'is', 'twenty', 'five']);
      expect(enTokenize('Hey Near, note: milk'), ['note', 'milk']);
    });
  });
}
