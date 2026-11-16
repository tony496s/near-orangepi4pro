"""Training a "Hey Near" openWakeWord model on a Mac (plan step C3): clips -> features -> model -> hey_near.onnx.

  WAKE_DATA=/path/to/wake-data python -m near_wake.train --config recipes/train.json \\
      --stage features|vi-negatives|train|all [--name RUN] [--overwrite]

openwakeword 0.6.0 has a training script (openwakeword/train.py, __main__) that cannot run here as it is: it always
imports piper-sample-generator (we synthesize with sherpa-onnx), feeds training through a DataLoader with
num_workers=cpu_count//2 (macOS spawns workers, which must pickle the batch generator, and fails), and converts the
model to tflite with TensorFlow. This driver calls the same library pieces on our own clip lists:

  features      Every run dir under synth/<split>/ (WAV + manifest.csv), minus TTS glitches longer than
                max_clip_seconds and minus negatives whose text holds an exclude_negative_texts phrase, plus real
                takes ($WAKE_DATA/real, split by speaker, train takes repeated real_repeat times). total_length is the
                median positive length + 0.75 s, at least 2 s, as in openwakeword. augment_clips (EQ, distortion,
                pitch, noise, background, room reverb) then compute_features_from_generator write
                runs/<name>/features/{positive,negative}_features_{train,test}.npy.
  vi-negatives  Embeds the long Vietnamese speech files (negatives-vi/train) once into runs/features-vi-train.npy,
                shaped like the ACAV100M features: (windows, 16, 96) float16, non-overlapping 16-frame (1.28 s)
                windows. Shared by every run; only --stage vi-negatives --overwrite rebuilds it.
  train         Model.auto_train on the big negative feature files (ACAV100M, Vietnamese speech) + positives +
                near-misses, mixed per batch by n_per_class; false positives per hour from
                validation_set_features.npy. Exports runs/<name>/hey_near.onnx: openwakeword names a model after
                its file, so the score key is "hey_near". Writes runs/<name>/run.json.
  all           The three in that order.

A stage skips outputs that exist, so a stopped run resumes; features made from another clip list or total_length are
refused (use --overwrite or another --name). Logs go to runs/<name>/train.log and stderr.

Mac specifics: training runs on the CPU. MPS runs openwakeword's Model (device set by hand) but was ~3x slower for
this tiny network in a benchmark (65 s against 20 s per 1000 steps on 4 CPU threads: transfers dominate), so it is not
offered. On 4 threads the recipe's 60000 steps took 2.7 s per 1000 steps, validations included. Batches come
from a DataLoader with num_workers=0 (no worker processes to spawn). Features use openwakeword's own ThreadPool
(ncpu = threads, threads not processes). "threads" also caps torch and the BLAS libraries.

Two openwakeword 0.6.0 behaviours to know when reading train.log: auto_train never updates best_val_fp, so sequences 2
and 3 always double max_negative_weight (1500 -> 3000 -> 6000); and it divides false positives by a fixed 11.3 h
while validation_set_features.npy holds 10.7 h. run.json's metrics use the real duration.
"""

from __future__ import annotations

import argparse
import copy
import csv
import glob
import hashlib
import json
import logging
import math
import os
import queue
import random
import re
import shutil
import sys
import threading
import time
import wave
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from . import texts as text_sets

log = logging.getLogger("near_wake.train")

SAMPLE_RATE = 16000
MODEL_NAME = "hey_near"  # the .onnx file stem, which openwakeword uses as the score key
WINDOW_FRAMES = 16  # model input: 16 embedding frames of 80 ms (about 2 s of audio with the melspectrogram context)
EMBEDDING_DIM = 96
FRAME_S = 0.08
FRAME_SAMPLES = 1280  # 80 ms
MIN_TOTAL_LENGTH = 32000  # openwakeword: at least 2 s per training clip...
TOTAL_LENGTH_PAD = 12000  # ...the median positive + 0.75 s...
TOTAL_LENGTH_SNAP = 4000  # ...and exactly 2 s when within 0.25 s of it
SPLITS = ("positive_train", "negative_train", "positive_test", "negative_test")
FEATURE_FILES = {
    "positive_train": "positive_features_train.npy",
    "negative_train": "negative_features_train.npy",
    "positive_test": "positive_features_test.npy",
    "negative_test": "negative_features_test.npy",
}
POSITIVE = "positive"
ADVERSARIAL = "adversarial_negative"
STAGES = ("features", "vi-negatives", "train", "all")
MISHEARINGS = "mishearings"
MATCH_MODES = ("phrase", "exact")
MODEL_TYPES = ("dnn", "rnn")
REAL_TRIM_DB = -35.0  # real takes: silence is quieter than this below the take's peak...
REAL_TRIM_PAD_S = 0.1  # ...and this much of it is kept on each side of the phrase
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
MIN_STEPS, MAX_STEPS = 100, 300000  # auto_train's later sequences run steps/10 with int16 validation steps

DEFAULTS: Dict[str, Any] = {
    "name": MODEL_NAME,
    "clips": {split: [f"synth/{split}/*"] for split in SPLITS},
    "max_clips": {},
    "max_clip_seconds": 4.0,
    "exclude_negative_texts": [],
    "exclude_negative_match": "phrase",
    "real_dir": "real",
    "real_test_speakers": None,
    "real_repeat": 20,
    "rir_dirs": ["assets/rir"],
    "background_dirs": ["assets/background"],
    "augmentation_rounds": 1,
    "augmentation_batch_size": 16,
    "vi_speech_dir": "negatives-vi/train",
    "vi_speech_features": "runs/features-vi-train.npy",
    "negative_features": {
        "ACAV100M": "assets/negatives/openwakeword_features_ACAV100M_2000_hrs_16bit.npy",
        "vi_speech": "runs/features-vi-train.npy",
    },
    "false_positive_validation": "assets/negatives/validation_set_features.npy",
    "n_per_class": {"ACAV100M": 1024, "vi_speech": 512, POSITIVE: 50, ADVERSARIAL: 50},
    "model_type": "dnn",
    "layer_size": 32,
    "steps": 50000,
    "max_negative_weight": 1500,
    "target_fp_per_hour": 0.2,
    "threads": 4,
    "seed": 0,
}


class ConfigError(ValueError):
    pass


class StageError(RuntimeError):
    """A stage cannot run: missing or stale inputs. The message says what to do."""


# ---------------------------------------------------------------------------------------------------------------
# Config

def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _str_list(v: Any) -> bool:
    return isinstance(v, list) and all(isinstance(s, str) and s.strip() for s in v)


def check_name(name: Any) -> str:
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise ConfigError(f"run name must match {NAME_RE.pattern}, got {name!r}")
    return name


def validate_config(cfg: Mapping[str, Any]) -> None:
    """ConfigError naming the first bad value of a merged config (DEFAULTS + file)."""
    def need(ok: bool, key: str, what: str) -> None:
        if not ok:
            raise ConfigError(f"{key}: {what}, got {cfg.get(key)!r}")

    check_name(cfg["name"])
    clips = cfg["clips"]
    need(isinstance(clips, dict) and set(clips) == set(SPLITS), "clips", f"an object with keys {', '.join(SPLITS)}")
    for split, patterns in clips.items():
        if not (_str_list(patterns) and patterns):
            raise ConfigError(f"clips.{split}: a non-empty list of directory globs, got {patterns!r}")
    mc = cfg["max_clips"]
    need(isinstance(mc, dict) and set(mc) <= set(SPLITS) and all(_is_int(v) and v >= 1 for v in mc.values()),
         "max_clips", f"an object mapping some of {', '.join(SPLITS)} to a count >= 1")
    need(cfg["max_clip_seconds"] is None or (_is_number(cfg["max_clip_seconds"]) and cfg["max_clip_seconds"] > 0),
         "max_clip_seconds", "null or seconds > 0")
    ex = cfg["exclude_negative_texts"]
    need(ex == MISHEARINGS or _str_list(ex), "exclude_negative_texts", f'"{MISHEARINGS}" or a list of texts')
    need(cfg["exclude_negative_match"] in MATCH_MODES, "exclude_negative_match", " or ".join(MATCH_MODES))
    need(cfg["real_dir"] is None or (isinstance(cfg["real_dir"], str) and cfg["real_dir"].strip()), "real_dir",
         "null or a directory")
    need(cfg["real_test_speakers"] is None or _str_list(cfg["real_test_speakers"]), "real_test_speakers",
         "null (automatic) or a list of speaker IDs")
    for key in ("real_repeat", "augmentation_rounds", "augmentation_batch_size", "layer_size"):
        need(_is_int(cfg[key]) and cfg[key] >= 1, key, "an integer >= 1")
    for key in ("rir_dirs", "background_dirs"):
        need(_str_list(cfg[key]), key, "a list of directories (may be empty)")
    for key in ("vi_speech_dir", "vi_speech_features", "false_positive_validation"):
        need(isinstance(cfg[key], str) and bool(cfg[key].strip()), key, "a path")
    neg = cfg["negative_features"]
    need(isinstance(neg, dict) and bool(neg) and all(isinstance(v, str) and v.strip() for v in neg.values())
         and not {POSITIVE, ADVERSARIAL} & set(neg), "negative_features",
         f"a non-empty object of name -> .npy path (names other than {POSITIVE}, {ADVERSARIAL})")
    want = set(neg) | {POSITIVE, ADVERSARIAL}
    npc = cfg["n_per_class"]
    need(isinstance(npc, dict) and set(npc) == want and all(_is_int(v) and v >= 1 for v in npc.values()),
         "n_per_class", f"a count >= 1 for each of {', '.join(sorted(want))}")
    need(cfg["model_type"] in MODEL_TYPES, "model_type", " or ".join(MODEL_TYPES))
    steps = cfg["steps"]
    need(_is_int(steps) and MIN_STEPS <= steps <= MAX_STEPS and steps % 10 == 0, "steps",
         f"a multiple of 10 in [{MIN_STEPS}, {MAX_STEPS}] (auto_train then runs steps/10 twice more)")
    need(_is_number(cfg["max_negative_weight"]) and cfg["max_negative_weight"] >= 1, "max_negative_weight",
         "a number >= 1")
    need(_is_number(cfg["target_fp_per_hour"]) and cfg["target_fp_per_hour"] > 0, "target_fp_per_hour",
         "a number > 0")
    need(_is_int(cfg["threads"]) and 1 <= cfg["threads"] <= 64, "threads", "an integer in [1, 64]")
    need(_is_int(cfg["seed"]), "seed", "an integer")


def load_config(path, env: Optional[Mapping[str, str]] = None) -> Dict[str, Any]:
    """The config file over DEFAULTS, validated, with "wake_data" (absolute) from the WAKE_DATA variable.

    Keys starting with "_" are comments. An object value replaces the default whole (no merging), so n_per_class
    always lists exactly the classes of negative_features. Unknown keys are errors (they are usually typos).
    """
    env = os.environ if env is None else env
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        raise ConfigError(f"{path}: {e}") from None
    if not isinstance(raw, dict):
        raise ConfigError(f"{path}: the config must be a JSON object")
    data = {k: v for k, v in raw.items() if not k.startswith("_")}
    unknown = sorted(set(data) - set(DEFAULTS))
    if unknown:
        raise ConfigError(f"{path}: unknown keys {', '.join(unknown)}; known: {', '.join(DEFAULTS)}")
    cfg = copy.deepcopy(DEFAULTS)
    cfg.update(copy.deepcopy(data))
    validate_config(cfg)
    root = env.get("WAKE_DATA", "").strip()
    if not root:
        raise ConfigError("set WAKE_DATA to the wake-data directory (config paths are relative to it)")
    # Absolute: openwakeword's trim_mmap strips the characters ".npy" from both ends of the path it is given.
    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise ConfigError(f"WAKE_DATA={root} is not a directory")
    cfg["wake_data"] = str(root_path)
    return cfg


def data_path(cfg: Mapping[str, Any], p: str) -> Path:
    """[p] relative to WAKE_DATA (an absolute path stays as it is)."""
    q = Path(p).expanduser()
    return q if q.is_absolute() else Path(cfg["wake_data"]) / q


# ---------------------------------------------------------------------------------------------------------------
# Clips

@dataclass(frozen=True)
class Clip:
    path: str
    text: str = ""
    seconds: Optional[float] = None
    speaker: str = ""


def wav_seconds(path) -> float:
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / float(w.getframerate())


def _float_or_none(v: Optional[str]) -> Optional[float]:
    try:
        x = float(v) if v not in (None, "") else None
    except ValueError:
        return None
    return x if x is not None and math.isfinite(x) else None


def read_clip_dir(d: Path) -> Tuple[List[Clip], int]:
    """(clips listed in d/manifest.csv whose WAV exists, rows whose WAV is missing), in manifest order.

    Clips are only taken through the manifest: synth.py writes the row after the WAV, so a listed clip is complete.
    """
    manifest = d / "manifest.csv"
    if not manifest.is_file():
        return [], 0
    clips, missing = [], 0
    with manifest.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            name = (row.get("file") or "").strip()
            if not name:
                continue
            p = d / name
            if not p.is_file():
                missing += 1
                continue
            clips.append(Clip(str(p), (row.get("text") or "").strip(), _float_or_none(row.get("seconds"))))
    return clips, missing


def clip_dirs(patterns: Sequence[str], root: Path) -> List[Path]:
    """Directories matched by [patterns] (globs relative to [root]), sorted, each once."""
    out: List[Path] = []
    for pattern in patterns:
        full = Path(pattern).expanduser()
        full = full if full.is_absolute() else root / full
        for m in sorted(glob.glob(str(full))):
            p = Path(m)
            if p.is_dir() and p not in out:
                out.append(p)
    return out


def negative_exclusions(cfg: Mapping[str, Any]) -> List[str]:
    ex = cfg["exclude_negative_texts"]
    return list(text_sets.MISHEARINGS_VI) if ex == MISHEARINGS else list(ex)


def is_excluded(text: str, phrases: Sequence[str], match: str = "phrase") -> bool:
    """Whether a negative clip saying [text] is dropped.

    "phrase": [text] contains one of [phrases] as a run of whole words ("thầy này dạy hay lắm" holds "thầy này"),
    "exact": [text] is one of them. Both after texts.normalize: case and punctuation ignored, tones kept.
    """
    if match == "exact":
        t = text_sets.normalize(text)
        return any(t == text_sets.normalize(p) for p in phrases)
    return any(text_sets.contains_phrase(text, p) for p in phrases)


def subsample(clips: Sequence[Clip], n: int, seed: str) -> List[Clip]:
    """[n] of [clips] chosen by [seed], in their original order (all of them when there are fewer)."""
    if len(clips) <= n:
        return list(clips)
    keep = set(random.Random(seed).sample(range(len(clips)), n))
    return [c for i, c in enumerate(clips) if i in keep]


def gather_clips(cfg: Mapping[str, Any]) -> Tuple[Dict[str, List[Clip]], Dict[str, Dict[str, Any]]]:
    """Synthetic clips per split from every directory the split's globs match, and what was dropped on the way.

    Dropped, in order: rows whose WAV is missing, clips longer than max_clip_seconds (TTS glitches), negatives
    excluded by exclude_negative_texts, then all but max_clips[split] (a seeded sample, for smoke runs).
    """
    root = Path(cfg["wake_data"])
    phrases = negative_exclusions(cfg)
    max_s = cfg["max_clip_seconds"]
    out: Dict[str, List[Clip]] = {}
    stats: Dict[str, Dict[str, Any]] = {}
    for split in SPLITS:
        st: Dict[str, Any] = {"dirs": {}, "missing_wav": 0, "too_long": 0, "excluded": 0, "excluded_texts": {},
                              "limited": 0}
        clips: List[Clip] = []
        for d in clip_dirs(cfg["clips"][split], root):
            got, missing = read_clip_dir(d)
            st["dirs"][str(d)] = len(got)
            st["missing_wav"] += missing
            clips.extend(got)
        if max_s is not None:
            kept = []
            for c in clips:
                s = c.seconds if c.seconds is not None else wav_seconds(c.path)
                if s > max_s:
                    st["too_long"] += 1
                else:
                    kept.append(c)
            clips = kept
        if split.startswith("negative") and phrases:
            kept = []
            for c in clips:
                if is_excluded(c.text, phrases, cfg["exclude_negative_match"]):
                    st["excluded"] += 1
                    st["excluded_texts"][c.text] = st["excluded_texts"].get(c.text, 0) + 1
                else:
                    kept.append(c)
            clips = kept
        limit = cfg["max_clips"].get(split)
        if limit is not None:
            before = len(clips)
            clips = subsample(clips, limit, f"near-wake-train:{cfg['seed']}:{split}")
            st["limited"] = before - len(clips)
        out[split] = clips
        stats[split] = st
    return out, stats


def read_real(real_dir: Path) -> List[Clip]:
    """Real "Hey Near" takes listed in real_dir/manifest.csv (near_wake.record), with their speaker.

    Free recordings (no phrase, *_free_*.wav) are not takes and are left out, as are rows without a WAV.
    """
    manifest = real_dir / "manifest.csv"
    if not manifest.is_file():
        return []
    out = []
    with manifest.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            name = (row.get("file") or "").strip()
            phrase = (row.get("phrase") or "").strip()
            if not name or "_free_" in name or not phrase:
                continue
            p = real_dir / name
            if p.is_file():
                out.append(Clip(str(p), phrase, _float_or_none(row.get("seconds")), (row.get("speaker") or "").strip()))
    return out


def auto_test_speakers(speakers: Sequence[str]) -> List[str]:
    """Held-out speakers when real_test_speakers is null: one in five (at least one) once there are two or more.

    Chosen by a hash of the name, so the choice does not depend on file order and mostly survives new speakers.
    """
    unique = sorted(set(speakers))
    if len(unique) < 2:
        return []
    ordered = sorted(unique, key=lambda s: hashlib.sha1(s.encode("utf-8")).hexdigest())
    return sorted(ordered[:max(1, len(unique) // 5)])


def split_by_speaker(clips: Sequence[Clip], test_speakers: Optional[Sequence[str]] = None
                     ) -> Tuple[List[Clip], List[Clip], List[str]]:
    """(train clips, test clips, test speakers): every take of a test speaker is a test clip."""
    tests = list(test_speakers) if test_speakers is not None else auto_test_speakers([c.speaker for c in clips])
    held = set(tests)
    return [c for c in clips if c.speaker not in held], [c for c in clips if c.speaker in held], sorted(held)


def trim_real_clip(src: str, dst: Path) -> Optional[float]:
    """Writes [src] without its leading and trailing silence to [dst] (kept if it exists); its seconds, or None if
    the take is silent.

    A take is the 0.8 s lead-in + 2 s; augment_clips keeps only the first total_length samples of a longer clip and
    puts the clip's end near the window's end, which is where the model learns to fire.
    """
    from .synth import read_wav_16k, trim_silence, write_wav

    if dst.is_file():
        return wav_seconds(dst)
    x = trim_silence(read_wav_16k(src), SAMPLE_RATE, REAL_TRIM_DB, REAL_TRIM_PAD_S)
    if len(x) == 0:
        return None
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(f".{dst.name}.tmp")
    write_wav(tmp, x)
    os.replace(tmp, dst)
    return len(x) / SAMPLE_RATE


def total_length_for(seconds: Sequence[float]) -> int:
    """Samples per training clip, as openwakeword's train.py sets it: the median positive length rounded to 1000
    samples + 12000 (0.75 s), at least 32000 (2 s), and 32000 when within 4000 of it."""
    if len(seconds) == 0:
        raise ValueError("no positive clips to measure")
    n = int(round(float(np.median(np.asarray(seconds, dtype=np.float64) * SAMPLE_RATE)) / 1000) * 1000)
    n += TOTAL_LENGTH_PAD
    if n < MIN_TOTAL_LENGTH or abs(n - MIN_TOTAL_LENGTH) <= TOTAL_LENGTH_SNAP:
        return MIN_TOTAL_LENGTH
    return n


@dataclass
class ClipPlan:
    paths: Dict[str, List[str]]  # per split, in augmentation order (rounds and real repeats included)
    total_length: int
    counts: Dict[str, Dict[str, Any]]
    real_test_speakers: List[str]


def plan_clips(cfg: Mapping[str, Any], real_out: Optional[Path] = None) -> ClipPlan:
    """Clip lists for the four feature sets, real takes included, and total_length.

    Real takes are trimmed into [real_out] (default: no real takes are used). Each list is shuffled with the seed:
    mmap_batch_generator reads feature rows in file order, and augment_clips gives a batch of clips the same
    background and room, so neighbouring rows must come from different runs, voices and speakers.
    """
    synth, stats = gather_clips(cfg)
    real_train: List[Clip] = []
    real_test: List[Clip] = []
    test_speakers: List[str] = []
    real_silent = 0
    if real_out is not None and cfg["real_dir"]:
        takes = read_real(data_path(cfg, cfg["real_dir"]))
        tr, te, test_speakers = split_by_speaker(takes, cfg["real_test_speakers"])
        for group, dest in ((tr, real_train), (te, real_test)):
            for c in group:
                s = trim_real_clip(c.path, real_out / Path(c.path).name)
                if s is None:
                    real_silent += 1
                else:
                    dest.append(Clip(str(real_out / Path(c.path).name), c.text, s, c.speaker))
    seconds = [c.seconds if c.seconds is not None else wav_seconds(c.path) for c in synth["positive_train"]]
    seconds += [c.seconds for c in real_train if c.seconds is not None]
    total_length = total_length_for(seconds)
    rounds = cfg["augmentation_rounds"]
    paths: Dict[str, List[str]] = {}
    counts: Dict[str, Dict[str, Any]] = {}
    for split in SPLITS:
        base = [c.path for c in synth[split]]
        real: List[str] = []
        if split == "positive_train":
            real = [c.path for c in real_train] * cfg["real_repeat"]
        elif split == "positive_test":
            real = [c.path for c in real_test]
        listed = (base + real) * rounds
        random.Random(f"near-wake-train:{cfg['seed']}:{split}:order").shuffle(listed)
        paths[split] = listed
        counts[split] = {"clips": len(listed), "synth": len(base), "real": len(set(real)), **stats[split]}
    counts["real_silent"] = real_silent
    return ClipPlan(paths, total_length, counts, test_speakers)


def wav_files(dirs: Sequence[str], cfg: Mapping[str, Any]) -> List[str]:
    """Every *.wav under [dirs] (recursively), sorted."""
    out: List[str] = []
    for d in dirs:
        p = data_path(cfg, d)
        if not p.is_dir():
            raise StageError(f"no directory {p}")
        out.extend(sorted(str(f) for f in p.rglob("*.wav") if f.is_file()))
    return out


# ---------------------------------------------------------------------------------------------------------------
# Features

def fingerprint(paths: Sequence[str], total_length: int) -> str:
    h = hashlib.sha1(str(total_length).encode())
    for p in paths:
        h.update(b"\0" + p.encode("utf-8"))
    return h.hexdigest()


def _read_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _write_json(path: Path, data: Mapping[str, Any]) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False, default=str) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def set_seeds(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed % (2 ** 32))
    try:
        import torch
    except ImportError:
        return
    torch.manual_seed(seed)


def run_features(cfg: Mapping[str, Any], run_dir: Path, overwrite: bool = False,
                 augment: Optional[Callable] = None, compute: Optional[Callable] = None) -> Dict[str, Any]:
    """Augmented clips -> openWakeWord features in run_dir/features/; returns what features.json records.

    [augment] and [compute] default to openwakeword.data.augment_clips and
    openwakeword.utils.compute_features_from_generator.
    """
    feat_dir = run_dir / "features"
    feat_dir.mkdir(parents=True, exist_ok=True)
    plan = plan_clips(cfg, run_dir / "real-clips")
    for split in SPLITS:
        if not plan.paths[split]:
            raise StageError(f"no clips for {split}: check clips.{split} in the config "
                             f"({', '.join(cfg['clips'][split])} under {cfg['wake_data']})")
    rirs = wav_files(cfg["rir_dirs"], cfg)
    backgrounds = wav_files(cfg["background_dirs"], cfg)
    log.info("features: total_length %d samples, %d RIRs, %d background files, clips %s", plan.total_length,
             len(rirs), len(backgrounds), {s: plan.counts[s]["clips"] for s in SPLITS})
    if augment is None:
        from openwakeword.data import augment_clips as augment
    if compute is None:
        from openwakeword.utils import compute_features_from_generator as compute
    shapes: Dict[str, List[int]] = {}
    seconds: Dict[str, float] = {}
    computed: List[str] = []
    for i, split in enumerate(SPLITS):
        paths = plan.paths[split]
        out = feat_dir / FEATURE_FILES[split]
        meta_path = out.with_suffix(".json")
        fp = fingerprint(paths, plan.total_length)
        if out.is_file() and not overwrite:
            meta = _read_json(meta_path)
            if meta.get("fingerprint") != fp:
                raise StageError(f"{out} was made from other clips or another total_length (the synth dirs or the "
                                 "config changed): rerun with --overwrite, or use another --name")
            log.info("features: %s exists, skipped", out.name)
            shapes[split] = meta.get("shape", [])
            seconds[split] = meta.get("seconds")
            continue
        t0 = time.time()
        set_seeds(cfg["seed"] + i)
        gen = augment(paths, total_length=plan.total_length, batch_size=min(cfg["augmentation_batch_size"], len(paths)),
                      background_clip_paths=backgrounds, RIR_paths=rirs)
        part = out.with_name(out.name + ".part")
        if part.exists():
            part.unlink()
        compute(gen, n_total=len(paths), clip_duration=plan.total_length, output_file=str(part), device="cpu",
                ncpu=cfg["threads"])
        arr = np.load(part, mmap_mode="r")
        shape = [int(v) for v in arr.shape]
        del arr
        if len(shape) != 3 or shape[1] < WINDOW_FRAMES or shape[2] != EMBEDDING_DIM:
            raise StageError(f"{part}: unexpected feature shape {shape}")
        os.replace(part, out)
        _write_json(meta_path, {"fingerprint": fp, "shape": shape, "clips": len(paths),
                                "total_length": plan.total_length, "seconds": round(time.time() - t0, 1)})
        shapes[split] = shape
        seconds[split] = round(time.time() - t0, 1)
        computed.append(split)
        log.info("features: %s %s in %.0f s (%.1f clips/s)", out.name, shape, seconds[split],
                 len(paths) / max(seconds[split], 1e-9))
    summary = {"total_length": plan.total_length, "clips": plan.counts, "shapes": shapes, "seconds": seconds,
               "real_test_speakers": plan.real_test_speakers, "rirs": len(rirs), "backgrounds": len(backgrounds)}
    _write_json(feat_dir / "features.json", summary)
    return {**summary, "computed": computed}


# ---------------------------------------------------------------------------------------------------------------
# Vietnamese speech negatives

def windows_for_samples(n: int) -> int:
    """Whole 16-frame windows openWakeWord's features give for [n] samples of 16 kHz audio.

    The melspectrogram has ceil(n/160 - 3) frames; an embedding frame takes 76 of them, every 8 (80 ms).
    """
    n_mel = math.ceil(n / 160 - 3)
    if n_mel < 76:
        return 0
    return ((n_mel - 76) // 8 + 1) // WINDOW_FRAMES


def usable_samples(n: int) -> int:
    """[n] samples cut down to whole 80 ms frames."""
    return n - n % FRAME_SAMPLES


def frames_to_windows(frames: np.ndarray, n: int = WINDOW_FRAMES) -> np.ndarray:
    """(frames, dim) embeddings -> (frames // n, n, dim) non-overlapping windows; the incomplete tail is dropped."""
    frames = np.asarray(frames)
    k = frames.shape[0] // n
    return frames[:k * n].reshape(k, n, frames.shape[-1])


def read_pcm16(path) -> np.ndarray:
    """int16 samples of a 16 kHz mono 16-bit WAV; ValueError for any other format."""
    with wave.open(str(path), "rb") as w:
        fmt = (w.getframerate(), w.getnchannels(), w.getsampwidth())
        if fmt != (SAMPLE_RATE, 1, 2):
            raise ValueError(f"{path}: need 16 kHz mono 16-bit, got {fmt[0]} Hz, {fmt[1]} ch, {8 * fmt[2]}-bit")
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int16)


def build_vi_speech(cfg: Mapping[str, Any], overwrite: bool = False,
                    embed: Optional[Callable[[np.ndarray], np.ndarray]] = None) -> Dict[str, Any]:
    """Embeds every WAV of vi_speech_dir into vi_speech_features, (windows, 16, 96) float16 like ACAV100M.

    Each file is embedded whole (as the device hears a stream) and cut into non-overlapping 16-frame windows. Files
    are cut to whole 80 ms frames first: for other lengths embed_clips' melspectrogram buffer can be one frame longer
    than the model's output, and it fails ("could not broadcast ... (60870,32) into ... (1,60871,32)").
    [embed] maps int16 samples to (frames, 96) embeddings; default openwakeword's AudioFeatures.embed_clips.
    """
    src = data_path(cfg, cfg["vi_speech_dir"])
    out = data_path(cfg, cfg["vi_speech_features"])
    meta_path = out.with_suffix(".json")
    files = sorted(src.glob("*.wav")) if src.is_dir() else []
    if not files:
        raise StageError(f"no .wav files in {src}")
    names = [f.name for f in files]
    if out.is_file() and not overwrite:
        meta = _read_json(meta_path)
        new = sorted(set(names) - set(meta.get("files", [])))
        if new:
            log.warning("vi-negatives: %d WAV files in %s are not in %s (e.g. %s); "
                        "--stage vi-negatives --overwrite rebuilds it", len(new), src, out.name, new[0])
        log.info("vi-negatives: %s exists, skipped", out)
        return {**meta, "built": False}
    counts = []
    for f in files:
        with wave.open(str(f), "rb") as w:
            fmt = (w.getframerate(), w.getnchannels(), w.getsampwidth())
            if fmt != (SAMPLE_RATE, 1, 2):
                raise StageError(f"{f}: need 16 kHz mono 16-bit, got {fmt}")
            counts.append(windows_for_samples(usable_samples(w.getnframes())))
    total = sum(counts)
    if total == 0:
        raise StageError(f"{src}: the files are too short for one {WINDOW_FRAMES}-frame window")
    if embed is None:
        from openwakeword.utils import AudioFeatures

        features = AudioFeatures(device="cpu")
        threads = cfg["threads"]

        def embed(x: np.ndarray) -> np.ndarray:
            return features.embed_clips(x[None, :], batch_size=1024, ncpu=threads)[0]

    out.parent.mkdir(parents=True, exist_ok=True)
    part = out.with_name(out.name + ".part")
    arr = np.lib.format.open_memmap(str(part), mode="w+", dtype=np.float16,
                                    shape=(total, WINDOW_FRAMES, EMBEDDING_DIM))
    t0, pos, done_s = time.time(), 0, 0.0
    for i, (f, k) in enumerate(zip(files, counts, strict=True)):
        x = read_pcm16(f)
        x = x[:usable_samples(len(x))]
        w = frames_to_windows(embed(x)) if k else np.zeros((0, WINDOW_FRAMES, EMBEDDING_DIM))
        if len(w) != k:
            raise StageError(f"{f}: expected {k} windows, the embedding gave {len(w)}")
        arr[pos:pos + k] = w.astype(np.float16)
        pos += k
        done_s += len(x) / SAMPLE_RATE
        if (i + 1) % 10 == 0 or i + 1 == len(files):
            el = time.time() - t0
            log.info("vi-negatives: %d/%d files, %.1f h of audio in %.0f s (%.0fx real time)", i + 1, len(files),
                     done_s / 3600, el, done_s / max(el, 1e-9))
    arr.flush()
    del arr
    os.replace(part, out)
    meta = {"files": names, "windows": total, "audio_hours": round(done_s / 3600, 4),
            "shape": [total, WINDOW_FRAMES, EMBEDDING_DIM], "dtype": "float16", "seconds": round(time.time() - t0, 1)}
    _write_json(meta_path, meta)
    log.info("vi-negatives: wrote %s %s", out, meta["shape"])
    return {**meta, "built": True}


# ---------------------------------------------------------------------------------------------------------------
# Training

def npy_layout(path) -> Tuple[Tuple[int, ...], np.dtype, int]:
    """(shape, dtype, bytes the file must have) from a .npy header."""
    with open(path, "rb") as f:
        version = np.lib.format.read_magic(f)
        if version == (1, 0):
            shape, _, dtype = np.lib.format.read_array_header_1_0(f)
        else:
            shape, _, dtype = np.lib.format.read_array_header_2_0(f)
        offset = f.tell()
    return tuple(shape), np.dtype(dtype), offset + int(np.prod(shape, dtype=np.int64)) * np.dtype(dtype).itemsize


def check_npy(path: Path, what: str) -> Tuple[int, ...]:
    """The shape of a complete .npy file; StageError when it is missing or shorter than its header says."""
    if not path.is_file():
        raise StageError(f"{what}: no {path}")
    shape, _, size = npy_layout(path)
    actual = path.stat().st_size
    if actual < size:
        raise StageError(f"{what}: {path} has {actual / 1e9:.2f} GB of {size / 1e9:.2f} GB (still downloading?)")
    return shape


def negative_windows(x: np.ndarray, n: int = WINDOW_FRAMES) -> np.ndarray:
    """Rows of a big negative feature file -> (windows, n, dim) model inputs.

    (k, n, dim) rows (ACAV100M, Vietnamese speech) are already windows; (frames, dim) rows (a features stream like
    validation_set_features.npy) and rows of another length are cut into consecutive non-overlapping n-frame windows.
    Replaces the f() of openwakeword's train.py, which also drops the last complete window.
    """
    x = np.asarray(x)
    if x.ndim == 3 and x.shape[1] == n:
        return x
    return frames_to_windows(x.reshape(-1, x.shape[-1]), n)


def last_frames(x: np.ndarray, n: int = WINDOW_FRAMES) -> np.ndarray:
    """Clip features (clips, frames, dim) -> their last [n] frames, where augment_clips puts the end of the phrase.

    Only longer than n when total_length is over 2 s; openwakeword's train.py has no transform for this case.
    """
    x = np.asarray(x)
    if x.ndim != 3 or x.shape[1] < n:
        raise ValueError(f"clip features need shape (clips, >= {n}, dim), got {x.shape}")
    return x if x.shape[1] == n else x[:, -n:, :]


def _ones(labels: Sequence) -> List[int]:
    return [1 for _ in labels]


def _zeros(labels: Sequence) -> List[int]:
    return [0 for _ in labels]


def label_transforms(classes: Sequence[str]) -> Dict[str, Callable[[Sequence], List[int]]]:
    """mmap_batch_generator labels a row with its class name; binary training wants 1 for positive, 0 otherwise."""
    return {c: (_ones if c == POSITIVE else _zeros) for c in classes}


def feature_sources(cfg: Mapping[str, Any], feat_dir: Path) -> Dict[str, str]:
    """mmap_batch_generator's data_files: the big negatives in config order, then positives and near-misses."""
    files = {name: str(data_path(cfg, p)) for name, p in cfg["negative_features"].items()}
    files[POSITIVE] = str(feat_dir / FEATURE_FILES["positive_train"])
    files[ADVERSARIAL] = str(feat_dir / FEATURE_FILES["negative_train"])
    return files


def data_transforms(classes: Sequence[str]) -> Dict[str, Callable[[np.ndarray], np.ndarray]]:
    return {c: (last_frames if c in (POSITIVE, ADVERSARIAL) else negative_windows) for c in classes}


class FalsePositiveWindows:
    """auto_train's false_positive_val_data: every n-frame window (step 1 frame) of a (frames, dim) feature stream,
    label 0, as (x, y) tensor batches. Built batch by batch: all 480k windows at once would take 3 GB."""

    def __init__(self, features: np.ndarray, n: int = WINDOW_FRAMES, batch: int = 65536) -> None:
        f = np.asarray(features)
        if f.ndim == 3:  # already windows
            self._windows = f
        elif f.ndim == 2 and f.shape[0] >= n:
            self._windows = np.lib.stride_tricks.sliding_window_view(f, (n, f.shape[1]))[:, 0]
        else:
            raise ValueError(f"false positive features need (frames >= {n}, dim) or (windows, n, dim), got {f.shape}")
        self.frames = f.shape[0] if f.ndim == 2 else f.shape[0] * f.shape[1]
        self.batch = batch

    @property
    def hours(self) -> float:
        return self.frames * FRAME_S / 3600

    def __len__(self) -> int:
        return len(self._windows)

    def __iter__(self) -> Iterator[Tuple[Any, Any]]:
        import torch

        for i in range(0, len(self._windows), self.batch):
            x = np.array(self._windows[i:i + self.batch], dtype=np.float32)  # a writable copy
            yield torch.from_numpy(x), torch.zeros(len(x), dtype=torch.float32)


class Prefetch:
    """The items of [source], produced [depth] ahead by a background thread.

    mmap_batch_generator spends about 5 ms building a batch (reading ACAV100M rows, float16 -> float32, stacking):
    as long as a training step. A thread overlaps the two; DataLoader worker processes cannot (macOS spawns them and
    the generator cannot be pickled). An exception in [source] is raised by the next() that reaches it.
    """

    _END = object()

    def __init__(self, source, depth: int = 8) -> None:
        self._q: queue.Queue = queue.Queue(maxsize=max(1, depth))
        self._done = False
        self._thread = threading.Thread(target=self._fill, args=(iter(source),), name="near-wake-prefetch",
                                        daemon=True)
        self._thread.start()

    def _fill(self, it) -> None:
        try:
            for item in it:
                self._q.put(item)
        except BaseException as e:  # handed to the consumer
            self._q.put(_Failure(e))
            return
        self._q.put(self._END)

    def __iter__(self) -> "Prefetch":
        return self

    def __next__(self) -> Any:
        if self._done:
            raise StopIteration
        item = self._q.get()
        if item is self._END:
            self._done = True
            raise StopIteration
        if isinstance(item, _Failure):
            self._done = True
            raise item.error
        return item


@dataclass
class _Failure:
    error: BaseException


class StepLog:
    """Iterable over the training batches that logs progress every [every] steps (auto_train's own bars are tqdm)."""

    def __init__(self, batches, model, total: int, every: int) -> None:
        self.batches, self.model, self.total, self.every = batches, model, total, max(1, every)
        self.step = 0
        self.t0: Optional[float] = None

    def __iter__(self) -> Iterator[Any]:
        if self.t0 is None:
            self.t0 = time.time()
        for batch in self.batches:
            self.step += 1
            if self.step % self.every == 0:
                self._log()
            yield batch

    def _last(self, key: str) -> str:
        values = getattr(self.model, "history", {}).get(key) or []
        return f"{float(np.asarray(values[-1])):.4g}" if len(values) else "-"

    def _log(self) -> None:
        el = time.time() - (self.t0 or time.time())
        rate = self.step / max(el, 1e-9)
        eta = max(0, self.total - self.step) / max(rate, 1e-9)
        # openwakeword's "recall" history is over the batch's hard examples only (positives scoring < 0.999).
        log.info("train: step %d/%d, %.1f steps/s, eta %.0f min; loss %s, hard-example recall %s, val recall %s, "
                 "val fp/h %s", self.step, self.total, rate, eta / 60, self._last("loss"), self._last("recall"),
                 self._last("val_recall"), self._last("val_fp_per_hr"))


def scores(model, batches) -> np.ndarray:
    """Model outputs (0..1) over (x, y) batches, flattened."""
    import torch

    out = []
    with torch.no_grad():
        for x, _ in batches:
            out.append(model(x).detach().cpu().numpy().ravel())
    return np.concatenate(out) if out else np.zeros(0)


def check_onnx(path: Path, x: np.ndarray, expected: np.ndarray) -> Dict[str, Any]:
    """Runs the exported model on [x] (one window at a time: the export has batch size 1) against torch's scores."""
    import onnxruntime as ort

    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    got = np.array([float(np.ravel(sess.run(None, {inp.name: x[i:i + 1].astype(np.float32)})[0])[0])
                    for i in range(len(x))])
    return {"input": inp.name, "input_shape": list(inp.shape),
            "max_abs_diff_vs_torch": float(np.max(np.abs(got - expected))) if len(x) else 0.0}


def run_train(cfg: Mapping[str, Any], run_dir: Path, overwrite: bool = False, model_cls: Optional[Callable] = None,
              batch_generator: Optional[Callable] = None) -> Optional[Dict[str, Any]]:
    """auto_train on the features, export run_dir/hey_near.onnx; what run.json records about it (None: skipped).

    [model_cls] and [batch_generator] default to openwakeword.train.Model and openwakeword.data.mmap_batch_generator.
    """
    feat_dir = run_dir / "features"
    model_path = run_dir / f"{MODEL_NAME}.onnx"
    if model_path.is_file() and not overwrite:
        log.info("train: %s exists, skipped (--overwrite trains again)", model_path)
        return None
    summary = _read_json(feat_dir / "features.json")
    if "total_length" not in summary:
        raise StageError(f"no {feat_dir / 'features.json'}: run --stage features first")
    for split in SPLITS:
        check_npy(feat_dir / FEATURE_FILES[split], split)
    for name, p in cfg["negative_features"].items():
        if data_path(cfg, p) == data_path(cfg, cfg["vi_speech_features"]) and not data_path(cfg, p).is_file():
            raise StageError(f"{name}: no {data_path(cfg, p)}: run --stage vi-negatives first")
        check_npy(data_path(cfg, p), name)
    fp_path = data_path(cfg, cfg["false_positive_validation"])
    check_npy(fp_path, "false_positive_validation")

    import torch

    torch.set_num_threads(cfg["threads"])
    set_seeds(cfg["seed"])
    if model_cls is None:
        from openwakeword.train import Model as model_cls
    if batch_generator is None:
        from openwakeword.data import mmap_batch_generator as batch_generator

    sources = feature_sources(cfg, feat_dir)
    gen = batch_generator(sources, n_per_class=dict(cfg["n_per_class"]), data_transform_funcs=data_transforms(
        list(sources)), label_transform_funcs=label_transforms(list(sources)))

    class IterDataset(torch.utils.data.IterableDataset):
        def __init__(self, g) -> None:
            super().__init__()
            self.g = g

        def __iter__(self):
            return self.g

    # num_workers=0: macOS starts DataLoader workers with spawn, which cannot pickle the generator; a thread
    # builds the batches ahead instead.
    loader = torch.utils.data.DataLoader(IterDataset(Prefetch(gen)), batch_size=None, num_workers=0)

    pos = last_frames(np.load(feat_dir / FEATURE_FILES["positive_test"])).astype(np.float32)
    neg = last_frames(np.load(feat_dir / FEATURE_FILES["negative_test"])).astype(np.float32)
    x_val = torch.from_numpy(np.concatenate([pos, neg]))
    y_val = torch.from_numpy(np.concatenate([np.ones(len(pos)), np.zeros(len(neg))]).astype(np.float32))
    val = [(x_val, y_val)]  # one batch: auto_train keeps the metrics of the last X_val batch only
    fp_val = FalsePositiveWindows(np.load(fp_path))

    input_shape = (WINDOW_FRAMES, EMBEDDING_DIM)
    oww = model_cls(n_classes=1, input_shape=input_shape, model_type=cfg["model_type"], layer_dim=cfg["layer_size"],
                    seconds_per_example=1280 * input_shape[0] / SAMPLE_RATE)
    steps = cfg["steps"]
    total = steps + 2 * (steps // 10)
    log.info("train: device cpu (%d threads), %s layer %d, %d steps (+2 x %d), batch %s = %d, val %d+%d clips, "
             "fp val %.1f h", cfg["threads"], cfg["model_type"], cfg["layer_size"], steps, steps // 10,
             dict(cfg["n_per_class"]), sum(cfg["n_per_class"].values()), len(pos), len(neg), fp_val.hours)
    t0 = time.time()
    best = oww.auto_train(X_train=StepLog(loader, oww, total, max(50, total // 100)), X_val=val,
                          false_positive_val_data=fp_val, steps=steps,
                          max_negative_weight=cfg["max_negative_weight"],
                          target_fp_per_hour=cfg["target_fp_per_hour"])
    train_s = time.time() - t0

    best.eval()
    pos_scores = scores(best, [(torch.from_numpy(pos), None)])
    neg_scores = scores(best, [(torch.from_numpy(neg), None)])
    fp_scores = scores(best, fp_val)
    metrics = {
        "threshold": 0.5,
        "positive_test_recall": float(np.mean(pos_scores >= 0.5)) if len(pos) else None,
        "negative_test_false_accepts": float(np.mean(neg_scores >= 0.5)) if len(neg) else None,
        "fp_windows_per_hour": float(np.sum(fp_scores >= 0.5) / fp_val.hours),
    }
    log.info("train: done in %.0f min: %s", train_s / 60, metrics)

    export_dir = run_dir / ".export"
    shutil.rmtree(export_dir, ignore_errors=True)
    export_dir.mkdir(parents=True)
    oww.export_model(model=best, model_name=MODEL_NAME, output_dir=str(export_dir))
    os.replace(export_dir / f"{MODEL_NAME}.onnx", model_path)
    shutil.rmtree(export_dir, ignore_errors=True)
    onnx = check_onnx(model_path, pos[:32], pos_scores[:32])
    log.info("train: exported %s (%s)", model_path, onnx)
    return {"model": str(model_path), "device": "cpu", "threads": cfg["threads"], "total_length":
            summary["total_length"], "input_shape": list(input_shape), "steps_run": total,
            "seconds_per_1000_steps": round(1000 * train_s / total, 1), "train_seconds": round(train_s, 1),
            "metrics": metrics, "onnx": onnx, "feature_rows": {k: list(check_npy(Path(v), k)) for k, v in
                                                               sources.items()}}


# ---------------------------------------------------------------------------------------------------------------
# CLI

def setup_logging(run_dir: Path) -> None:
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s", "%Y-%m-%d %H:%M:%S")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    for h in list(root.handlers):
        if getattr(h, "_near_wake", False):
            root.removeHandler(h)
    for h in (logging.FileHandler(run_dir / "train.log", encoding="utf-8"), logging.StreamHandler(sys.stderr)):
        h.setFormatter(fmt)
        h._near_wake = True  # type: ignore[attr-defined]
        root.addHandler(h)


def update_run_json(run_dir: Path, **fields: Any) -> Dict[str, Any]:
    path = run_dir / "run.json"
    data = _read_json(path)
    timings = {**data.get("timings", {}), **fields.pop("timings", {})}
    data.update(fields)
    data["timings"] = timings
    data["updated_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _write_json(path, data)
    return data


def needs_vi_speech(cfg: Mapping[str, Any]) -> bool:
    target = data_path(cfg, cfg["vi_speech_features"])
    return any(data_path(cfg, p) == target for p in cfg["negative_features"].values())


def quiet_library_warnings() -> None:
    """Hides the deprecation notices torch_audiomentations, torchaudio and audiomentations print while augmenting."""
    import warnings

    for module in ("torch_audiomentations", "torchaudio"):
        warnings.filterwarnings("ignore", category=FutureWarning, module=module)
        warnings.filterwarnings("ignore", category=UserWarning, module=module)
    warnings.filterwarnings("ignore", message=r".*input samples dtype is np\.float64", category=UserWarning)


def limit_threads(n: int) -> None:
    """Caps the thread pools read at import time (torch's OpenMP, BLAS); call before importing torch."""
    for var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "MKL_NUM_THREADS"):
        os.environ[var] = str(n)


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="python -m near_wake.train", description=__doc__.splitlines()[0])
    p.add_argument("--config", required=True, type=Path, help="JSON recipe, e.g. recipes/train.json")
    p.add_argument("--stage", required=True, choices=STAGES)
    p.add_argument("--name", help="run name (default: the config's name); outputs go to $WAKE_DATA/runs/<name>/")
    p.add_argument("--overwrite", action="store_true",
                   help="redo the stage's outputs (the shared Vietnamese cache only with --stage vi-negatives)")
    args = p.parse_args(argv)
    try:
        cfg = load_config(args.config)
        if args.name:
            cfg["name"] = check_name(args.name)
    except ConfigError as e:
        p.error(str(e))
    run_dir = Path(cfg["wake_data"]) / "runs" / cfg["name"]
    run_dir.mkdir(parents=True, exist_ok=True)
    limit_threads(cfg["threads"])
    quiet_library_warnings()
    setup_logging(run_dir)
    log.info("%s: stage %s, run %s", args.config, args.stage, run_dir)
    update_run_json(run_dir, name=cfg["name"], config_file=str(args.config.resolve()), config=cfg)
    try:
        if args.stage in ("features", "all"):
            t0 = time.time()
            feats = run_features(cfg, run_dir, overwrite=args.overwrite)
            timings = {"features_s": round(time.time() - t0, 1)} if feats["computed"] else {}
            update_run_json(run_dir, clips=feats["clips"], total_length=feats["total_length"],
                            real_test_speakers=feats["real_test_speakers"], feature_seconds=feats["seconds"],
                            timings=timings)
        if args.stage == "vi-negatives" or (args.stage == "all" and needs_vi_speech(cfg)):
            t0 = time.time()
            vi = build_vi_speech(cfg, overwrite=args.overwrite and args.stage == "vi-negatives")
            timings = {"vi_negatives_s": round(time.time() - t0, 1)} if vi["built"] else {}
            update_run_json(run_dir, vi_speech={k: v for k, v in vi.items() if k not in ("files", "built")},
                            timings=timings)
        if args.stage in ("train", "all"):
            t0 = time.time()
            info = run_train(cfg, run_dir, overwrite=args.overwrite)
            if info is not None:
                feats = _read_json(run_dir / "features" / "features.json")
                update_run_json(run_dir, train=info, **{k: feats[k] for k in ("clips", "total_length") if k in feats},
                                timings={"train_s": round(time.time() - t0, 1)})
    except (StageError, ValueError, OSError) as e:
        log.error("%s", e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
