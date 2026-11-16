# Near

Desk strip app for an Orange Pi 4 Pro with a 1480×320 touch bar display: an ambient "day strip" (clock, next event,
timeline), timers and focus sessions, quick notes and reminders, driven by touch and local Vietnamese voice commands.

Status: demo M1 in progress. See `docs/superpowers/specs/2026-11-16-near-demo-design.md`.

Layout:

- `app/` Flutter app, runs on the board with flutter-pi (no X, no Wayland). `flutter test <files>`, `flutter analyze`.
- `voice/` local voice service (sherpa-onnx: Silero VAD + Zipformer-vi), talks to the app over localhost. See
  `voice/README.md`.
- `deploy/` build, install and systemd units for the board (planned).
