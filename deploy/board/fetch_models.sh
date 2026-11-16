#!/bin/sh
# Puts the models near-voice needs into $NEAR_MODELS (default ~/near/models): Silero VAD and Zipformer-vi 30M int8,
# plus the zh-en keyword spotter for the wake word trial (optional: near-voice runs without a wake word when missing).
# Copies them from the Phase 0 downloads when they are on the board, otherwise downloads the sherpa-onnx release files.
# Skips what is already there. Exit code 1 if VAD or STT is missing at the end.
set -u
URL=${NEAR_MODELS_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models}
KWS_URL=${NEAR_KWS_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models}
M=${NEAR_MODELS:-$HOME/near/models}
SEED=${NEAR_MODELS_SEED:-$HOME/phase0/stt/models}
KWS_SEED=${NEAR_KWS_SEED:-$HOME/phase0/wake/models}
CURL=${NEAR_CURL:-curl -sSfL}
VAD=silero_vad.onnx
STT=sherpa-onnx-zipformer-vi-30M-int8-2026-02-09
STT_FILES="encoder.int8.onnx decoder.onnx joiner.int8.onnx tokens.txt"
KWS=sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20
KWS_FILES="encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx decoder-epoch-13-avg-2-chunk-16-left-64.onnx joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx tokens.txt"

mkdir -p "$M" || exit 1

complete() {  # complete <dir> <files>
    for f in $2; do [ -s "$1/$f" ] || return 1; done
}

fetch_dir() {  # fetch_dir <name> <files> <release url> <seed dir>
    if complete "$M/$1" "$2"; then
        echo "have $1"
        return
    fi
    rm -rf "$M/$1" "$M/.extract"
    if complete "$4/$1" "$2"; then
        cp -R "$4/$1" "$M/.extract" && mv "$M/.extract" "$M/$1" && echo "copied $1 from $4"
    else
        mkdir -p "$M/.extract" \
            && $CURL -o "$M/.extract/$1.tar.bz2" "$3/$1.tar.bz2" \
            && tar xjf "$M/.extract/$1.tar.bz2" -C "$M/.extract" \
            && mv "$M/.extract/$1" "$M/$1" && echo "downloaded $1"
    fi
    rm -rf "$M/.extract"
}

if [ -s "$M/$VAD" ]; then
    echo "have $VAD"
elif [ -s "$SEED/$VAD" ]; then
    cp "$SEED/$VAD" "$M/$VAD.part" && mv "$M/$VAD.part" "$M/$VAD" && echo "copied $VAD from $SEED"
else
    $CURL -o "$M/$VAD.part" "$URL/$VAD" && mv "$M/$VAD.part" "$M/$VAD" && echo "downloaded $VAD"
fi
rm -f "$M/$VAD.part"

fetch_dir "$STT" "$STT_FILES" "$URL" "$SEED"
fetch_dir "$KWS" "$KWS_FILES" "$KWS_URL" "$KWS_SEED"

ok=0
[ -s "$M/$VAD" ] || { echo "MISSING $M/$VAD" >&2; ok=1; }
complete "$M/$STT" "$STT_FILES" || { echo "MISSING or incomplete $M/$STT" >&2; ok=1; }
complete "$M/$KWS" "$KWS_FILES" || echo "WARNING no $M/$KWS: near-voice runs without the wake word" >&2
exit $ok
