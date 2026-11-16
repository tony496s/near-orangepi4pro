#!/bin/sh
# Synthetic clips for the first "Hey Near" model (plan step C3). Reproducible: every run has a fixed seed, and a run
# that stops can be started again (clips already written are skipped).
#
#   WAKE_DATA=/path/to/wake-data sh wake/recipes/synth.sh
#
# Needs $WAKE_DATA/env (python with sherpa-onnx, numpy, scipy) and the Piper voices in $WAKE_DATA/assets/tts. Writes
# $WAKE_DATA/synth/<split>/<run>/ (WAV + manifest.csv). Nothing here goes into git.
#
# The Vietnamese voices vais1000 and 25hours_single say "hây nia" in about 0.3 s, so they run slower (--speed) than
# vivos and the English voices; the near-misses use the same speeds as the positives, so pace is no clue.
set -eu
: "${WAKE_DATA:?set WAKE_DATA to the wake-data directory}"
PY="$WAKE_DATA/env/bin/python"
T="$WAKE_DATA/assets/tts"
OUT="$WAKE_DATA/synth"
LOGS="$WAKE_DATA/logs"
cd "$(dirname "$0")/.."
mkdir -p "$OUT" "$LOGS"

EN="--voice $T/vits-piper-en_US-libritts_r-medium --voice $T/vits-piper-en_US-l2arctic-medium --voice $T/vits-piper-en_GB-vctk-medium"
VIVOS="--voice $T/vits-piper-vi_VN-vivos-x_low"
VI_FAST="--voice $T/vits-piper-vi_VN-vais1000-medium --voice $T/vits-piper-vi_VN-25hours_single-low"
SLOW="--speed 0.45,0.75"

run() {  # run <split> <name> <texts> <n> <seed> <voice and speed args...>
    split=$1 name=$2 texts=$3 n=$4 seed=$5
    shift 5
    # shellcheck disable=SC2086
    "$PY" -m near_wake.synth "$@" --texts "$texts" --n "$n" --seed "$seed" --out "$OUT/$split/$name" --threads 2 \
        >"$LOGS/synth-$split-$name.log" 2>&1
    tail -1 "$LOGS/synth-$split-$name.log"
}

# Five lanes of about the same length, two sherpa-onnx threads each.
( run positive_train en      positive-en    12000 1 $EN ) &
( run positive_train vi      positive-vi     4000 2 $VIVOS
  run positive_train vi-slow positive-vi     3000 3 $VI_FAST $SLOW
  run positive_test  vi      positive-vi      400 12 $VIVOS
  run positive_test  vi-slow positive-vi      300 13 $VI_FAST $SLOW ) &
( run negative_train en      adversarial-en  6000 4 $EN
  run negative_test  en      adversarial-en   600 14 $EN
  run positive_test  en      positive-en     1000 11 $EN ) &
( run negative_train vi      adversarial-vi  5000 5 $VIVOS
  run negative_test  vi      adversarial-vi   300 15 $VIVOS ) &
( run negative_train vi-slow adversarial-vi  3000 6 $VI_FAST $SLOW
  run negative_test  vi-slow adversarial-vi   300 16 $VI_FAST $SLOW ) &
wait
echo "synth done: $(find "$OUT" -name '*.wav' | wc -l) clips in $OUT"
