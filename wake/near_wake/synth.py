"""Synthetic "Hey Near" (and near-miss) clips from Piper VITS voices through sherpa-onnx, for openWakeWord training.

  python3 -m near_wake.synth --voice DIR [--voice DIR ...] --texts positive-en|positive-vi|adversarial-vi|adversarial-en
                             --n N --out DIR [--seed S]

Clip i picks a voice, a speaker, a text, a speed (0.8-1.25) and a noise setting, all from (seed, i) alone, so a run is
reproducible and can be resumed: clips already written (WAV file and manifest row) are skipped. Each clip is resampled
to 16 kHz mono, trimmed of silence at both ends and normalized to a peak between -3 and -1 dBFS, then written as
<out>/<texts>_<NNNNN>.wav (16-bit) with a row in <out>/manifest.csv.

A voice dir is what sherpa-onnx ships for a Piper voice: one *.onnx model, tokens.txt and espeak-ng-data/. VITS fixes
noise_scale, noise_scale_w and length_scale when the OfflineTts object is built, so each voice gets one object per
noise setting (built on first use); speed is a per-call argument of generate(). The audio data and models never go
into git.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import random
import sys
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Set, Tuple

import numpy as np

from . import texts as text_sets

SAMPLE_RATE = 16000
SPEED_RANGE = (0.8, 1.25)
PEAK_DBFS_RANGE = (-3.0, -1.0)
TRIM_DB = -40.0  # silence: quieter than this relative to the clip's peak
TRIM_PAD_S = 0.03  # kept on each side of the sound so a soft onset ("h") survives the trim
# (noise_scale, noise_scale_w): Piper's defaults first, then a flatter and a livelier delivery.
NOISE_SETTINGS: Tuple[Tuple[float, float], ...] = ((0.667, 0.8), (0.4, 0.5), (0.9, 1.1))
MANIFEST = "manifest.csv"
MANIFEST_FIELDS = ["file", "voice", "speaker", "text", "speed", "noise_scale", "noise_scale_w", "seconds", "seed"]


# ---------------------------------------------------------------------------------------------------------------
# Audio helpers (also used by evaluate.py)

def _resample_poly():
    try:
        from scipy.signal import resample_poly
    except ImportError:
        return None
    return resample_poly


def resample_linear(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    """[x] at [sr_out] by linear interpolation (no anti-alias filter): the fallback when scipy is missing.

    The length matches scipy's resample_poly: ceil(len(x) * sr_out / sr_in).
    """
    x = np.asarray(x, dtype=np.float32)
    if sr_in == sr_out or len(x) == 0:
        return x.copy()
    g = math.gcd(int(sr_in), int(sr_out))
    up, down = sr_out // g, sr_in // g
    n_out = -(-len(x) * up // down)
    t = np.arange(n_out, dtype=np.float64) * (sr_in / sr_out)
    return np.interp(t, np.arange(len(x), dtype=np.float64), x).astype(np.float32)


def resample(x: np.ndarray, sr_in: int, sr_out: int = SAMPLE_RATE) -> np.ndarray:
    """[x] (float, mono) at [sr_out]: scipy's polyphase filter if scipy is importable, else linear interpolation."""
    x = np.asarray(x, dtype=np.float32)
    if sr_in == sr_out or len(x) == 0:
        return x.copy()
    poly = _resample_poly()
    if poly is None:
        return resample_linear(x, sr_in, sr_out)
    g = math.gcd(int(sr_in), int(sr_out))
    return poly(x, sr_out // g, sr_in // g).astype(np.float32)


def trim_silence(x: np.ndarray, sr: int = SAMPLE_RATE, rel_db: float = TRIM_DB,
                 pad_s: float = TRIM_PAD_S) -> np.ndarray:
    """[x] without the silence at both ends: samples quieter than [rel_db] below the peak, keeping [pad_s] of margin.

    All-silent (or empty) input gives an empty array.
    """
    x = np.asarray(x, dtype=np.float32)
    mag = np.abs(x)
    peak = float(mag.max()) if len(x) else 0.0
    if peak <= 0.0:
        return x[:0].copy()
    loud = np.flatnonzero(mag >= peak * 10 ** (rel_db / 20))
    pad = int(round(pad_s * sr))
    return x[max(0, loud[0] - pad):min(len(x), loud[-1] + 1 + pad)].copy()


def normalize_peak(x: np.ndarray, peak_dbfs: float) -> np.ndarray:
    """[x] scaled so its largest absolute sample is [peak_dbfs] (1.0 == 0 dBFS). Silence stays silence."""
    x = np.asarray(x, dtype=np.float32)
    peak = float(np.abs(x).max()) if len(x) else 0.0
    if peak <= 0.0:
        return x.copy()
    return (x * (10 ** (peak_dbfs / 20) / peak)).astype(np.float32)


def to_int16(x: np.ndarray) -> np.ndarray:
    """Float samples in [-1, 1] as int16 (clipped)."""
    return np.clip(np.round(np.asarray(x, dtype=np.float64) * 32767.0), -32768, 32767).astype(np.int16)


def write_wav(path, samples: np.ndarray, sr: int = SAMPLE_RATE) -> None:
    """16-bit mono WAV; [samples] is int16, or float in [-1, 1]."""
    pcm = samples if np.asarray(samples).dtype == np.int16 else to_int16(samples)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sr))
        w.writeframes(np.asarray(pcm, dtype="<i2").tobytes())


def read_wav(path) -> Tuple[np.ndarray, int]:
    """(float32 mono samples in [-1, 1], sample rate) of a PCM WAV file (8/16/24/32-bit; channels are averaged)."""
    with wave.open(str(path), "rb") as w:
        channels, width, sr = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    if width == 1:
        x = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    elif width == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif width == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = (np.where(v >= 1 << 23, v - (1 << 24), v)).astype(np.float32) / float(1 << 23)
    elif width == 4:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float32) / float(1 << 31)
    else:
        raise ValueError(f"{path}: unsupported sample width {width}")
    if channels > 1:
        x = x[: len(x) - len(x) % channels].reshape(-1, channels).mean(axis=1)
    return x.astype(np.float32), sr


def read_wav_16k(path) -> np.ndarray:
    """A WAV file as float32 mono at 16 kHz."""
    x, sr = read_wav(path)
    return resample(x, sr, SAMPLE_RATE)


def process(samples: np.ndarray, sr: int, peak_dbfs: float) -> np.ndarray:
    """TTS output -> the clip that is written: 16 kHz, trimmed, peak at [peak_dbfs], int16. Empty if it was silent."""
    x = trim_silence(resample(samples, sr, SAMPLE_RATE), SAMPLE_RATE)
    return to_int16(normalize_peak(x, peak_dbfs))


# ---------------------------------------------------------------------------------------------------------------
# Voices

def find_voice_files(voice_dir) -> Dict[str, str]:
    """model (*.onnx, a non-int8 one when there is a choice), tokens (tokens.txt), data_dir (espeak-ng-data)."""
    d = Path(voice_dir)
    if not d.is_dir():
        raise FileNotFoundError(f"no voice dir {d}")
    models = sorted(p for p in d.glob("*.onnx") if p.is_file())
    if not models:
        raise FileNotFoundError(f"{d}: no *.onnx model")
    full = [p for p in models if ".int8." not in p.name]
    tokens, data_dir = d / "tokens.txt", d / "espeak-ng-data"
    if not tokens.is_file():
        raise FileNotFoundError(f"{d}: no tokens.txt")
    if not data_dir.is_dir():
        raise FileNotFoundError(f"{d}: no espeak-ng-data/")
    return {"model": str((full or models)[0]), "tokens": str(tokens), "data_dir": str(data_dir)}


def sherpa_tts(voice_dir, noise_scale: float, noise_scale_w: float, threads: int = 1):
    """A sherpa_onnx.OfflineTts for the Piper VITS voice in [voice_dir] with these noise settings.

    API as of sherpa-onnx 2.0.1 (checked by introspecting the installed module): OfflineTtsVitsModelConfig(model,
    lexicon, tokens, data_dir, dict_dir, noise_scale, noise_scale_w, length_scale), OfflineTtsModelConfig(vits=,
    num_threads=, debug=, provider=), OfflineTtsConfig(model=, rule_fsts=, rule_fars=, max_num_sentences=,
    silence_scale=), OfflineTts(config) with properties num_speakers and sample_rate, and
    generate(text, sid=0, speed=1.0) -> GeneratedAudio(.samples, .sample_rate).
    """
    import sherpa_onnx as so

    f = find_voice_files(voice_dir)
    vits = so.OfflineTtsVitsModelConfig(model=f["model"], lexicon="", tokens=f["tokens"], data_dir=f["data_dir"],
                                        noise_scale=float(noise_scale), noise_scale_w=float(noise_scale_w),
                                        length_scale=1.0)
    config = so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(vits=vits, num_threads=threads, provider="cpu"),
                                 max_num_sentences=1)
    if not config.validate():
        raise ValueError(f"{voice_dir}: sherpa-onnx rejected the TTS config")
    return so.OfflineTts(config)


TtsFactory = Callable[[str, float, float], object]


class VoicePool:
    """One TTS object per (voice, noise setting), built on first use by [factory](voice_dir, noise_scale,
    noise_scale_w).

    A TTS object is anything shaped like sherpa_onnx.OfflineTts: num_speakers, and generate(text, sid=, speed=)
    returning something with samples and sample_rate.
    """

    def __init__(self, voice_dirs: Sequence[str], factory: TtsFactory,
                 noise_settings: Sequence[Tuple[float, float]] = NOISE_SETTINGS) -> None:
        if not voice_dirs:
            raise ValueError("no voices")
        if not noise_settings:
            raise ValueError("no noise settings")
        self.voice_dirs = [str(v) for v in voice_dirs]
        self.noise_settings = list(noise_settings)
        self._factory = factory
        self._cache: Dict[Tuple[int, int], object] = {}

    def tts(self, voice: int, noise: int):
        key = (voice, noise)
        if key not in self._cache:
            ns, nsw = self.noise_settings[noise]
            self._cache[key] = self._factory(self.voice_dirs[voice], ns, nsw)
        return self._cache[key]

    def voice_name(self, voice: int) -> str:
        return os.path.basename(os.path.normpath(self.voice_dirs[voice]))

    @property
    def built(self) -> int:
        return len(self._cache)


# ---------------------------------------------------------------------------------------------------------------
# Planning and running

@dataclass(frozen=True)
class ClipPlan:
    index: int
    text: str
    voice: int  # index into the voice list
    noise: int  # index into the noise settings
    speed: float
    speaker_u: float  # in [0, 1): the speaker is int(speaker_u * num_speakers), known only once the TTS is built
    peak_dbfs: float


def plan_clip(index: int, seed: int, text: str, n_voices: int, n_noise: int) -> ClipPlan:
    """Choices for clip [index], from (seed, index) alone: skipping or redoing other clips never changes them."""
    rng = random.Random(f"near-wake-synth:{seed}:{index}")
    voice = rng.randrange(n_voices)
    noise = rng.randrange(n_noise)
    speed = round(rng.uniform(*SPEED_RANGE), 3)
    speaker_u = rng.random()
    peak = round(rng.uniform(*PEAK_DBFS_RANGE), 2)
    return ClipPlan(index, text, voice, noise, speed, speaker_u, peak)


def speaker_for(speaker_u: float, num_speakers: int) -> int:
    n = max(1, int(num_speakers))  # a single-speaker model may report 0
    return min(int(speaker_u * n), n - 1)


def clip_name(set_name: str, index: int) -> str:
    return f"{set_name}_{index:05d}.wav"


def read_manifest(path) -> List[Dict[str, str]]:
    """Rows of the manifest at [path] (none if it does not exist)."""
    p = Path(path)
    if not p.is_file() or p.stat().st_size == 0:
        return []
    with open(p, newline="", encoding="utf-8") as f:
        return [row for row in csv.DictReader(f) if row.get("file")]


def finished_clips(out_dir) -> Set[str]:
    """Clips in [out_dir] that are done: their WAV exists and the manifest has a row for them.

    Rows whose WAV is gone are dropped from the manifest (it is rewritten), so redoing such a clip leaves one row.
    """
    out = Path(out_dir)
    manifest = out / MANIFEST
    rows = read_manifest(manifest)
    kept = [r for r in rows if (out / r["file"]).is_file()]
    if len(kept) != len(rows):
        tmp = out / (MANIFEST + ".tmp")
        with open(tmp, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=MANIFEST_FIELDS, extrasaction="ignore")
            w.writeheader()
            w.writerows(kept)
        os.replace(tmp, manifest)
    return {r["file"] for r in kept}


def append_manifest(path, row: Dict[str, object]) -> None:
    p = Path(path)
    new = not p.is_file() or p.stat().st_size == 0
    with open(p, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=MANIFEST_FIELDS)
        if new:
            w.writeheader()
        w.writerow(row)


def synthesize(voice_dirs: Sequence[str], set_name: str, n: int, out_dir, seed: int = 0,
               factory: Optional[TtsFactory] = None, noise_settings: Sequence[Tuple[float, float]] = NOISE_SETTINGS,
               log: Callable[[str], None] = print) -> Dict[str, int]:
    """Writes clips 0..n-1 of [set_name] into [out_dir]; returns counts of written, skipped and failed clips.

    A clip counts as done when its WAV exists and the manifest has its row; anything else is (re)synthesized. The
    WAV is written to a temporary name and renamed, then its row is appended, so a crash never leaves a row without
    a complete file.
    """
    lines = text_sets.text_set(set_name)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    manifest = out / MANIFEST
    done = finished_clips(out)
    pool = VoicePool(voice_dirs, factory or sherpa_tts, noise_settings)
    counts = {"written": 0, "skipped": 0, "failed": 0}
    for i, text in enumerate(text_sets.variants(lines, n, seed)):
        name = clip_name(set_name, i)
        path = out / name
        if name in done:
            counts["skipped"] += 1
            continue
        plan = plan_clip(i, seed, text, len(pool.voice_dirs), len(pool.noise_settings))
        tts = pool.tts(plan.voice, plan.noise)
        sid = speaker_for(plan.speaker_u, getattr(tts, "num_speakers", 1))
        audio = tts.generate(text, sid=sid, speed=plan.speed)
        clip = process(np.asarray(audio.samples, dtype=np.float32), int(audio.sample_rate), plan.peak_dbfs)
        if len(clip) == 0:
            log(f"{name}: {pool.voice_name(plan.voice)} speaker {sid} gave no audio for {text!r}; skipped")
            counts["failed"] += 1
            continue
        tmp = out / (name + ".tmp")
        write_wav(tmp, clip)
        os.replace(tmp, path)
        ns, nsw = pool.noise_settings[plan.noise]
        append_manifest(manifest, {"file": name, "voice": pool.voice_name(plan.voice), "speaker": sid, "text": text,
                                   "speed": plan.speed, "noise_scale": ns, "noise_scale_w": nsw,
                                   "seconds": round(len(clip) / SAMPLE_RATE, 3), "seed": seed})
        counts["written"] += 1
        if counts["written"] % 100 == 0:
            log(f"{set_name}: {i + 1}/{n} ({counts['written']} written, {counts['skipped']} skipped)")
    return counts


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="python3 -m near_wake.synth", description=__doc__.splitlines()[0])
    p.add_argument("--voice", action="append", required=True, metavar="DIR",
                   help="Piper voice dir (*.onnx, tokens.txt, espeak-ng-data/); repeat for more voices")
    p.add_argument("--texts", required=True, choices=list(text_sets.TEXT_SETS))
    p.add_argument("--n", type=int, required=True, help="number of clips")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--threads", type=int, default=2, help="sherpa-onnx threads per TTS object")
    args = p.parse_args(argv)
    if args.n < 0:
        p.error("--n must be >= 0")
    for v in args.voice:
        find_voice_files(v)  # fail before any work if a voice dir is incomplete
    factory = lambda d, ns, nsw: sherpa_tts(d, ns, nsw, threads=args.threads)  # noqa: E731
    counts = synthesize(args.voice, args.texts, args.n, args.out, seed=args.seed, factory=factory)
    print(f"{args.texts}: {counts['written']} written, {counts['skipped']} skipped, {counts['failed']} failed "
          f"-> {args.out}")
    return 1 if counts["failed"] and not counts["written"] and not counts["skipped"] else 0


if __name__ == "__main__":
    sys.exit(main())
