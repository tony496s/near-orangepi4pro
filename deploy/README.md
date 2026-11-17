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

## Demo: agent console (`feat/agent-console`)

A second app in the same bundle: `NEAR_MODE=agents` shows the agent console (agents running in the box, given work by
voice) instead of the day strip. It is deployed next to the strip, in `~/near/app-agents`, and switched on with a systemd
drop-in, so going back is one file away. Steps, the demo script and the hidden controls:
`docs/superpowers/specs/2026-11-17-agent-console-demo-design.md` (sections 4–6).

### Get the demo back: `near-demo`

The demo is frozen at the tag `demo/agent-console-v1`. From any folder on the Mac:

```
near-demo                 # build the tag, copy it to ~/near/app-agents, switch the board to the demo, restart, check
near-demo --off           # back to the normal app (~/near/app), no build
```

It builds in its own clone of the tag (`~/.cache/near-demo/src`, forced back to the tag and cleaned on every run, about
40 s in all), so it gives the same demo whatever happens on the branches, `app/lib/agents` deleted included. It stops
before building when the board is unreachable or not set up, and fails unless `near-app` is active and healthy about
20 s after the restart (then it prints the journal). It builds with the Flutter SDK that `flutterpi_tool` was activated
against, whatever Flutter comes first on PATH, and warns if that is not 3.47.9, the version the demo was checked with
(`NEAR_FLUTTER_ROOT=<sdk>` picks another). The demo starts in manual mode; a double tap on the left rail turns autoplay
on. `near-voice` is the board's own, not part of the tag.

- Once per Mac: `install -m 755 deploy/near-demo-launcher.sh ~/.local/bin/near-demo` (any checkout of the tag).
- Once per board set up before this: `near-demo --setup-board` asks for the board's sudo password and installs
  `near-app.service.d/mode.conf` (`board/near-app-mode.conf`; `install.sh` installs it too), which makes `near-app`
  read `~/near/mode.env`. near-demo writes that file and `--off` deletes it, so switching needs no password, only the
  NOPASSWD `systemctl restart near-app`. Without the file the unit runs as before. It also removes the old
  `agents.conf` drop-in.
- Which board: `near-demo <ssh-host>`, or `NEAR_BOARD` / `NEAR_SSH_OPTS` for one run; otherwise
  `~/.config/near/board.env` (outside the repo; `NEAR_CONFIG=<file>` picks another), otherwise `opi`. Anything given for
  the run replaces the file as a whole, so `NEAR_SSH_OPTS= near-demo` is plain `opi` from `~/.ssh/config`. For a board
  reached over IPv6 link-local (`%%` because ssh expands `%`):

  ```
  NEAR_BOARD=opi
  NEAR_SSH_OPTS="-o HostName=<ipv6>%%<interface> -o HostKeyAlias=<name it has in known_hosts>"
  ```
