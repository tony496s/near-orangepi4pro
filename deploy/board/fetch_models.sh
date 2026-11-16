#!/bin/sh
# Puts the models near-voice needs into $NEAR_MODELS (default ~/near/models): Silero VAD and Zipformer-vi 30M int8.
# Copies them from the Phase 0 download when it is on the board, otherwise downloads the sherpa-onnx release files.
# Skips what is already there. Exit code 1 if anything is missing at the end.
set -u
URL=${NEAR_MODELS_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models}
M=${NEAR_MODELS:-$HOME/near/models}
SEED=${NEAR_MODELS_SEED:-$HOME/phase0/stt/models}
CURL=${NEAR_CURL:-curl -sSfL}
VAD=silero_vad.onnx
STT=sherpa-onnx-zipformer-vi-30M-int8-2026-02-09
STT_FILES="encoder.int8.onnx decoder.onnx joiner.int8.onnx tokens.txt"

mkdir -p "$M" || exit 1

stt_complete() {
    for f in $STT_FILES; do [ -s "$1/$f" ] || return 1; done
}

if [ -s "$M/$VAD" ]; then
    echo "have $VAD"
elif [ -s "$SEED/$VAD" ]; then
    cp "$SEED/$VAD" "$M/$VAD.part" && mv "$M/$VAD.part" "$M/$VAD" && echo "copied $VAD from $SEED"
else
    $CURL -o "$M/$VAD.part" "$URL/$VAD" && mv "$M/$VAD.part" "$M/$VAD" && echo "downloaded $VAD"
fi

if stt_complete "$M/$STT"; then
    echo "have $STT"
else
    rm -rf "$M/$STT" "$M/.extract"
    if stt_complete "$SEED/$STT"; then
        cp -R "$SEED/$STT" "$M/.extract" && mv "$M/.extract" "$M/$STT" && echo "copied $STT from $SEED"
    else
        mkdir -p "$M/.extract" \
            && $CURL -o "$M/.extract/$STT.tar.bz2" "$URL/$STT.tar.bz2" \
            && tar xjf "$M/.extract/$STT.tar.bz2" -C "$M/.extract" \
            && mv "$M/.extract/$STT" "$M/$STT" && echo "downloaded $STT"
        rm -rf "$M/.extract"
    fi
fi
rm -f "$M/$VAD.part"

ok=0
[ -s "$M/$VAD" ] || { echo "MISSING $M/$VAD" >&2; ok=1; }
stt_complete "$M/$STT" || { echo "MISSING or incomplete $M/$STT" >&2; ok=1; }
exit $ok
