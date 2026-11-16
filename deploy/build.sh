#!/bin/sh
# Builds the app bundle for the board (arm64, release AOT) into app/build/flutter-pi/aarch64-generic. Runs on a Mac.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL=${FLUTTERPI_TOOL:-}
if [ -z "$TOOL" ]; then
    if command -v flutterpi_tool >/dev/null 2>&1; then TOOL=flutterpi_tool; else TOOL=$HOME/.pub-cache/bin/flutterpi_tool; fi
fi
cd "$ROOT/app"
"$TOOL" build --arch=arm64 --release
echo "bundle: $ROOT/app/build/flutter-pi/aarch64-generic"
