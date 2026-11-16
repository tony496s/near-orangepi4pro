# Deploy to the board

Everything Near needs lives in `~/near` on the board (user `orangepi`), and the system only gets a boot wrapper and
two systemd units:

```
~/near/app      Flutter bundle (flutterpi_tool build) + flutter-pi (vsync-patched build from Phase 0)
~/near/voice    near-voice (rsync of voice/)
~/near/venv     Python venv for near-voice (voice/requirements.txt)
~/near/models   silero_vad.onnx + sherpa-onnx-zipformer-vi-30M-int8-2026-02-09 (+ the zh-en KWS model for the wake word)
~/near/secrets  harness-auth.json: the board's Harness sign-in for cloud speech to text (owner only, never in git)
~/near/deploy   board/ scripts
/usr/local/sbin/near-app-start                    boot wrapper (guard, fbcon, HDMI hotplug mask, GPU module)
/etc/systemd/system/near-{app,voice}.service      both only start when /etc/near/autostart exists
```

## Steps

On the Mac:

```
deploy/build.sh
deploy/push.sh <ssh-host>                # extra ssh options in NEAR_SSH_OPTS
```

On the board, the first time (and after changing `voice/requirements.txt` or the units):

```
near/deploy/setup.sh                     # venv, models (copied from ~/phase0/stt/models when present), flutter-pi
sudo near/deploy/install.sh              # wrapper + units, daemon-reload, enable; does not switch what boots
```

`near-voice` runs Vietnamese on the local model, English (the app's VI/EN switch) through Harness, and the wake word
trial on (see the unit). For English, sign the board in once from a Mac, then copy the file (`voice/README.md`); until
then the app shows no VI/EN switch:

```
python3 voice/tools/harness_login.py
scp ~/.near/harness-auth.json <ssh-host>:near/secrets/harness-auth.json
```

## Switch the display between Phase 0 and Near

`near-app` conflicts with `phase0-flutter` and `lightdm`: starting one stops the others. Keep exactly one autostart
flag so the next boot is unambiguous.

```
# Near on, now and at boot
sudo rm -f /etc/phase0/flutter-autostart && sudo touch /etc/near/autostart && sudo systemctl start near-app

# back to the Phase 0 strip
sudo rm -f /etc/near/autostart && sudo systemctl stop near-app near-voice \
  && sudo touch /etc/phase0/flutter-autostart && sudo systemctl start phase0-flutter
```

After a code change: `deploy/build.sh && deploy/push.sh <host>`, then `sudo systemctl restart near-app` (and
`near-voice` if `voice/` changed).

Logs: `journalctl -u near-app -u near-voice -f`. App state: `~/.local/share/near/state.json`.

## Test

```
python3 -m unittest discover -s deploy -p 'test_*.py'
```

## Demo: the calendar changes, the network drops (scenario 6)

- The sample 1:1 (14:30) moves to 14:00 by itself 20 minutes after the app starts (`NEAR_DEMO_MOVE_AFTER=<minutes>`
  or `off` in the unit's environment). To show it on cue: `kill -USR2 $(pidof flutter-pi)` moves it now and fetches
  the calendar at once: "LỊCH VỪA ĐỔI · 14:30 → 14:00", and the old slot stays dashed on the timeline until 14:30.
  It only moves while 14:00 is still ahead; restart `near-app` to start over.
- Take the board off Wi-Fi: within about 40 s the strip shows "MẤT MẠNG" with the time the calendar was last fetched.
  Timers and Vietnamese voice commands keep working (speech to text runs on the board).
