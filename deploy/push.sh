#!/bin/sh
# Copies the app bundle, the voice service and the board scripts into ~/near on the board. Nothing here needs root.
#
#   deploy/push.sh <ssh-host>            (or NEAR_BOARD=<ssh-host>)
#
# Extra ssh options (e.g. for an IPv6 link-local address) go in NEAR_SSH_OPTS.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST=${1:-${NEAR_BOARD:-}}
if [ -z "$HOST" ]; then
    echo "usage: deploy/push.sh <ssh-host>   (or NEAR_BOARD=<ssh-host>)" >&2
    exit 2
fi
BUNDLE=${NEAR_BUNDLE_DIR:-$ROOT/app/build/flutter-pi/aarch64-generic}
if [ ! -f "$BUNDLE/app.so" ]; then
    echo "no bundle in $BUNDLE: run deploy/build.sh first" >&2
    exit 1
fi
SSH="${NEAR_SSH:-ssh} ${NEAR_SSH_OPTS:-}"
RSYNC=${NEAR_RSYNC:-rsync}

$SSH "$HOST" 'mkdir -p near/app near/voice near/deploy' < /dev/null
# The board runs the vsync-patched flutter-pi that setup.sh installs; the bundle's stock one is kept as a fallback.
$RSYNC -a --delete --exclude flutter-pi --exclude flutter-pi.stock -e "$SSH" "$BUNDLE/" "$HOST:near/app/"
$RSYNC -a -e "$SSH" "$BUNDLE/flutter-pi" "$HOST:near/app/flutter-pi.stock"
$RSYNC -a --delete --exclude __pycache__ -e "$SSH" "$ROOT/voice/" "$HOST:near/voice/"
$RSYNC -a --delete -e "$SSH" "$ROOT/deploy/board/" "$HOST:near/deploy/"
echo "pushed to $HOST:near/"
echo "first time on the board: near/deploy/setup.sh && sudo near/deploy/install.sh"
