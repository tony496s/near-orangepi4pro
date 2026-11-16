# Deploy to the board

Everything Near needs lives in `~/near` on the board (user `orangepi`), and the system only gets a boot wrapper and
two systemd units:

```
~/near/app      Flutter bundle (flutterpi_tool build) + flutter-pi (vsync-patched build from Phase 0)
~/near/voice    near-voice (rsync of voice/)
~/near/venv     Python venv for near-voice (voice/requirements.txt)
~/near/models   silero_vad.onnx + sherpa-onnx-zipformer-vi-30M-int8-2026-02-09
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
