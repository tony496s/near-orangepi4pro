#!/bin/sh
# Installs the Near boot wrapper and systemd units (run with sudo on the board). Safe to re-run.
# It does not change what boots: the units only start when /etc/near/autostart exists (see deploy/README.md).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${NEAR_ROOT:-}  # tests install into a scratch directory instead of /
if [ -z "$ROOT" ] && [ "$(id -u)" != 0 ]; then
    echo "run with sudo" >&2
    exit 1
fi
put() {  # put <src> <dest> <mode>
    mkdir -p "$(dirname "$ROOT$2")"
    cp "$HERE/$1" "$ROOT$2.tmp" && chmod "$3" "$ROOT$2.tmp" && mv "$ROOT$2.tmp" "$ROOT$2"
    echo "installed $2"
}
put near-app-start.sh /usr/local/sbin/near-app-start 755
put near-app.service /etc/systemd/system/near-app.service 644
put near-voice.service /etc/systemd/system/near-voice.service 644
mkdir -p "$ROOT/etc/near"
if [ -z "$ROOT" ]; then
    systemctl daemon-reload
    systemctl enable near-app.service near-voice.service
fi
