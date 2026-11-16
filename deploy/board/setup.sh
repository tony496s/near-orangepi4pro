#!/bin/sh
# Board setup as the normal user, safe to re-run: Python venv for near-voice, models, and the flutter-pi binary.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
NEAR=${NEAR_HOME:-$HOME/near}
PYTHON=${NEAR_PYTHON-python3}
PATCHED=${NEAR_FLUTTER_PI:-$HOME/phase0/flutter-pi-src/build/flutter-pi}

if [ -n "$PYTHON" ]; then
    [ -x "$NEAR/venv/bin/python" ] || "$PYTHON" -m venv "$NEAR/venv"
    "$NEAR/venv/bin/python" -m pip install -q -r "$NEAR/voice/requirements.txt"
    echo "venv ready: $NEAR/venv"
fi

NEAR_MODELS=${NEAR_MODELS:-$NEAR/models} "$HERE/fetch_models.sh"

if [ -x "$PATCHED" ]; then
    cp "$PATCHED" "$NEAR/app/flutter-pi.tmp" && chmod 755 "$NEAR/app/flutter-pi.tmp"
    mv "$NEAR/app/flutter-pi.tmp" "$NEAR/app/flutter-pi"
    echo "flutter-pi: vsync-patched build from $PATCHED"
elif [ -x "$NEAR/app/flutter-pi.stock" ]; then
    cp "$NEAR/app/flutter-pi.stock" "$NEAR/app/flutter-pi"
    echo "flutter-pi: WARNING no patched build at $PATCHED, using the stock one (about 4% dropped frames)"
else
    echo "flutter-pi: missing, push the bundle first (deploy/push.sh)" >&2
    exit 1
fi
