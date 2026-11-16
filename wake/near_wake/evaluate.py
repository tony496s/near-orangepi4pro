"""Scoring a "Hey Near" openWakeWord model: recall on positive clips, false alarms per hour on negative audio.

  python3 -m near_wake.evaluate --model M.onnx --pos DIR_OR_GLOB ... --neg FILE_OR_DIR ... [--e4 [DIR]]
                                [--thresholds 0.3,0.5,0.7,0.9] [--cooldown 2.0] [--json out.json]

The model scores every 80 ms frame (1280 samples at 16 kHz) from about 1.28 s of context. A positive clip is padded
with 1.0 s of silence before and 0.5 s after (so the window sees all of it) and is a hit when its highest frame score
reaches the threshold. Negative audio (long recordings, or short near-miss clips) is streamed the same way; frames at
or above the threshold are detections, merged within the cooldown as on the device (after a hit nothing fires for
cooldown_s), and every detection is a false alarm.

--e4 also scores the phase 0 E4 session, a real recording of the user: 20 commands, then 12 "Hey Near" takes. As in
phase 0 E5 (kws_eval.py), the takes are every VAD segment from the first one the STT alignment mapped to a wake prompt
(W01...) onward; a detection near a take is a hit, any other detection a false alarm.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Protocol, Sequence, Tuple

import numpy as np

from .synth import read_wav_16k

SAMPLE_RATE = 16000
FRAME = 1280  # samples per model frame (80 ms)
FRAME_S = FRAME / SAMPLE_RATE
PAD_BEFORE_S = 1.0
PAD_AFTER_S = 0.5
DEFAULT_THRESHOLDS = (0.3, 0.5, 0.7, 0.9)
DEFAULT_COOLDOWN_S = 2.0
# The E4 session where phase0/ sits next to the checkout (phase0/data/e4: results/summary.json,
# segments/segments.json, session1.wav).
DEFAULT_E4_DIR = Path(__file__).resolve().parents[3] / "phase0" / "data" / "e4"
E4_SUMMARY = Path("results") / "summary.json"
E4_SEGMENTS = Path("segments") / "segments.json"
E4_WAV = Path("session1.wav")


class Scorer(Protocol):
    def reset(self) -> None:
        """Forgets the audio fed so far."""

    def score(self, frame: np.ndarray) -> float:
        """Feeds one frame (int16, FRAME samples at 16 kHz); the wake word score after it, 0..1."""


class OwwScorer:
    """An openWakeWord model (a custom .onnx) behind the Scorer interface.

    openwakeword 0.6.0 API (read in openwakeword/model.py and utils.py): Model(wakeword_models=[path],
    inference_framework="onnx", **kwargs) forwards melspec_model_path / embedding_model_path to AudioFeatures, whose
    defaults are resources/models/{melspectrogram,embedding_model}.onnx inside the package (fetched by
    openwakeword.utils.download_models()). A model loaded from a path is named after its file stem, and
    predict(int16 array) returns {name: score} (or {class label: score} for a multi-class model). The first 5
    predictions after a reset are forced to 0. reset() clears the prediction and feature buffers.
    """

    def __init__(self, model_path, melspec_path=None, embedding_path=None) -> None:
        if not os.path.isfile(model_path):
            raise FileNotFoundError(f"no model {model_path}")
        import openwakeword
        from openwakeword.model import Model

        resources = os.path.join(os.path.dirname(os.path.abspath(openwakeword.__file__)), "resources", "models")
        melspec = str(melspec_path) if melspec_path else os.path.join(resources, "melspectrogram.onnx")
        embedding = str(embedding_path) if embedding_path else os.path.join(resources, "embedding_model.onnx")
        for p in (melspec, embedding):
            if not os.path.isfile(p):
                raise FileNotFoundError(f"no {p}: pass --melspec/--embedding, or run "
                                        "python3 -c 'import openwakeword.utils as u; u.download_models()'")
        self.name = Path(model_path).stem
        self._model = Model(wakeword_models=[str(model_path)], inference_framework="onnx",
                            melspec_model_path=melspec, embedding_model_path=embedding)

    def reset(self) -> None:
        self._model.reset()

    def score(self, frame: np.ndarray) -> float:
        preds = self._model.predict(np.asarray(frame, dtype=np.int16))
        if self.name in preds:
            return float(preds[self.name])
        return float(max(preds.values(), default=0.0))


# ---------------------------------------------------------------------------------------------------------------
# Streaming

def as_int16(samples: np.ndarray) -> np.ndarray:
    """int16 samples as they are; float samples in [-1, 1] scaled and clipped to int16."""
    x = np.asarray(samples)
    if x.dtype == np.int16:
        return x
    if np.issubdtype(x.dtype, np.floating):
        return np.clip(np.round(x * 32767.0), -32768, 32767).astype(np.int16)
    return np.clip(x, -32768, 32767).astype(np.int16)


def frame_scores(scorer: Scorer, samples: np.ndarray, pad_before_s: float = PAD_BEFORE_S,
                 pad_after_s: float = PAD_AFTER_S) -> Tuple[np.ndarray, np.ndarray]:
    """(times, scores) of every frame of [samples] streamed through a freshly reset [scorer].

    The audio is padded with silence ([pad_before_s] before, [pad_after_s] after, then up to a whole frame). A
    frame's time is when it ends, in seconds from the start of [samples] (frames inside the leading pad are < 0).
    """
    x = as_int16(samples)
    before, after = int(round(pad_before_s * SAMPLE_RATE)), int(round(pad_after_s * SAMPLE_RATE))
    total = before + len(x) + after
    total += -total % FRAME
    padded = np.zeros(total, dtype=np.int16)
    padded[before:before + len(x)] = x
    scorer.reset()
    n = total // FRAME
    scores = np.empty(n, dtype=np.float64)
    for k in range(n):
        scores[k] = float(scorer.score(padded[k * FRAME:(k + 1) * FRAME]))
    times = (np.arange(1, n + 1) * FRAME - before) / SAMPLE_RATE
    return times, scores


def score_clip(scorer: Scorer, samples: np.ndarray) -> float:
    """Highest frame score of a clip padded with 1.0 s of silence before and 0.5 s after. Hit: >= threshold."""
    _, scores = frame_scores(scorer, samples)
    return float(scores.max()) if len(scores) else 0.0


def detections(times: Sequence[float], scores: Sequence[float], threshold: float,
               cooldown_s: float = DEFAULT_COOLDOWN_S) -> List[float]:
    """Times of frames scoring >= [threshold], each one more than [cooldown_s] after the previous detection kept.

    That is the device's cooldown: after a hit, nothing fires for cooldown_s, then a new hit can.
    """
    out: List[float] = []
    last: Optional[float] = None
    for t, s in zip(times, scores, strict=True):
        if s >= threshold and (last is None or t - last >= cooldown_s - 1e-9):
            last = float(t)
            out.append(round(max(0.0, last), 3))
    return out


def scan_stream(scorer: Scorer, samples: np.ndarray, threshold: float,
                cooldown_s: float = DEFAULT_COOLDOWN_S) -> List[float]:
    """Detection times (s from the start) in a long recording, merged within [cooldown_s] as on the device."""
    times, scores = frame_scores(scorer, samples)
    return detections(times, scores, threshold, cooldown_s)


# ---------------------------------------------------------------------------------------------------------------
# Recall and false alarms

Clip = Tuple[str, np.ndarray]  # (name, 16 kHz samples)


def evaluate(scorer_factory: Callable[[], Scorer], positives: Iterable[Clip], negatives: Iterable[Clip],
             thresholds: Sequence[float] = DEFAULT_THRESHOLDS, cooldown_s: float = DEFAULT_COOLDOWN_S) -> Dict:
    """Recall and false alarms of one model at every threshold.

    [scorer_factory] is called once; the scorer is reset before each clip. [positives] and [negatives] may be
    generators (each clip is loaded, scored and dropped in turn). Each negative is streamed once; detections at every
    threshold come from the same frame scores.

    Returns {"positives", "negative_files", "negative_hours", "positive_scores": {name: max score},
    "thresholds": [{"threshold", "hits", "positives", "recall", "missed": [names], "false_alarms",
    "fa_per_hour", "false_alarm_times": {negative name: [s]}}]}. recall and fa_per_hour are None without
    positives / negative audio.
    """
    ths = [float(t) for t in thresholds]
    scorer = scorer_factory()
    pos_scores: Dict[str, float] = {}
    for name, samples in positives:
        pos_scores[name] = score_clip(scorer, samples)
    fa_times: Dict[float, Dict[str, List[float]]] = {t: {} for t in ths}
    neg_seconds, neg_files = 0.0, 0
    for name, samples in negatives:
        neg_files += 1
        neg_seconds += len(samples) / SAMPLE_RATE
        times, scores = frame_scores(scorer, samples)
        for t in ths:
            fa_times[t][name] = detections(times, scores, t, cooldown_s)
    hours = neg_seconds / 3600.0
    rows = []
    for t in ths:
        missed = [n for n, s in pos_scores.items() if s < t]
        hits = len(pos_scores) - len(missed)
        fa = sum(len(v) for v in fa_times[t].values())
        rows.append({
            "threshold": t, "hits": hits, "positives": len(pos_scores),
            "recall": hits / len(pos_scores) if pos_scores else None, "missed": missed,
            "false_alarms": fa, "fa_per_hour": fa / hours if hours > 0 else None,
            "false_alarm_times": {n: v for n, v in fa_times[t].items() if v},
        })
    return {"positives": len(pos_scores), "negative_files": neg_files, "negative_hours": hours,
            "positive_scores": pos_scores, "thresholds": rows}


# ---------------------------------------------------------------------------------------------------------------
# E4: the user's own session (phase 0)

def wake_spans(summary: Dict, segments: List[Dict]) -> List[Tuple[float, float]]:
    """(start_s, end_s) of every segment from the first one mapped to a wake prompt (id starting with W) onward.

    Same rule as phase0/wake/kws_eval.py: a take the STT left unmatched still counts, since the session ends with
    the wake prompts.
    """
    wake_segs = [s for m in summary["mapping"] if m["id"].startswith("W") for s in m["segs"]]
    if not wake_segs:
        return []
    first = min(wake_segs)
    return [(float(seg["start_s"]), float(seg["end_s"])) for seg in sorted(segments, key=lambda s: s["seg"])
            if seg["seg"] >= first]


def score_events(events: Sequence[float], spans: Sequence[Tuple[float, float]], before_s: float = 0.3,
                 after_s: float = 1.5) -> Dict:
    """Hits: spans with at least one event inside [start - before_s, end + after_s]. Other events are false alarms.

    From phase0/wake/kws_eval.py. after_s allows for the model firing a little after the keyword ends. One event
    counts for one span only; a second event on an already hit span is neither a hit nor a false alarm.
    """
    hit = [False] * len(spans)
    false_alarms = []
    for t in events:
        for k, (a, b) in enumerate(spans):
            if not hit[k] and a - before_s <= t <= b + after_s:
                hit[k] = True
                break
        else:
            if not any(a - before_s <= t <= b + after_s for a, b in spans):
                false_alarms.append(t)
    return {"positives": len(spans), "hits": sum(hit), "missed": [k for k, h in enumerate(hit) if not h],
            "false_alarms": false_alarms}


def non_wake_seconds(total_s: float, spans: Sequence[Tuple[float, float]], before_s: float = 0.3,
                     after_s: float = 1.5) -> float:
    """Seconds of [0, total_s] outside every take's tolerance window: the audio where a detection is a false alarm."""
    windows = sorted((max(0.0, a - before_s), min(total_s, b + after_s)) for a, b in spans)
    covered, end = 0.0, 0.0
    for a, b in windows:
        a = max(a, end)
        if b > a:
            covered += b - a
            end = b
    return max(0.0, total_s - covered)


def load_e4(e4_dir, summary: Optional[Path] = None, segments: Optional[Path] = None,
            wav: Optional[Path] = None) -> Dict:
    """The E4 session's files and takes: {"wav", "summary", "segments", "spans"}.

    Defaults inside [e4_dir]: results/summary.json (the STT alignment: mapping of prompt ids to segments),
    segments/segments.json (the VAD segments: seg, start_s, end_s in the session) and session1.wav.
    """
    d = Path(e4_dir)
    paths = {"summary": Path(summary) if summary else d / E4_SUMMARY,
             "segments": Path(segments) if segments else d / E4_SEGMENTS,
             "wav": Path(wav) if wav else d / E4_WAV}
    for key, p in paths.items():
        if not p.is_file():
            raise FileNotFoundError(f"E4 {key}: no {p}")
    summary_data = json.loads(paths["summary"].read_text(encoding="utf-8"))
    segments_data = json.loads(paths["segments"].read_text(encoding="utf-8"))
    spans = wake_spans(summary_data, segments_data)
    if not spans:
        raise ValueError(f"{paths['summary']}: no segment mapped to a wake prompt (W...)")
    return {**paths, "spans": spans}


def evaluate_session(scorer: Scorer, samples: np.ndarray, spans: Sequence[Tuple[float, float]],
                     thresholds: Sequence[float] = DEFAULT_THRESHOLDS,
                     cooldown_s: float = DEFAULT_COOLDOWN_S) -> Dict:
    """A long recording with known takes ([spans]): hits and false alarms at every threshold, from one pass.

    Returns {"seconds", "non_wake_seconds", "thresholds": [{"threshold", "positives", "hits", "missed" (take
    indexes), "false_alarms" (times), "fa_per_hour", "detections"}]}.
    """
    total_s = len(samples) / SAMPLE_RATE
    neg_s = non_wake_seconds(total_s, spans)
    times, scores = frame_scores(scorer, samples)
    rows = []
    for t in thresholds:
        events = detections(times, scores, float(t), cooldown_s)
        s = score_events(events, spans)
        rows.append({"threshold": float(t), **s, "detections": events,
                     "fa_per_hour": len(s["false_alarms"]) / (neg_s / 3600.0) if neg_s > 0 else None})
    return {"seconds": total_s, "non_wake_seconds": neg_s, "thresholds": rows}


# ---------------------------------------------------------------------------------------------------------------
# CLI

def expand_paths(items: Sequence[str], suffix: str = ".wav") -> List[Path]:
    """Files named by [items]: a directory gives its *.wav (recursively), a glob its matches, a file itself.

    FileNotFoundError for an item that names nothing.
    """
    out: List[Path] = []
    for item in items:
        p = Path(item)
        if p.is_dir():
            found = sorted(f for f in p.rglob(f"*{suffix}") if f.is_file())
        elif p.is_file():
            found = [p]
        elif glob.has_magic(item):
            found = sorted(Path(f) for f in glob.glob(item, recursive=True) if os.path.isfile(f))
        else:
            found = []
        if not found:
            raise FileNotFoundError(f"no {suffix} files for {item}")
        out.extend(found)
    seen, unique = set(), []
    for f in out:
        if f not in seen:
            seen.add(f)
            unique.append(f)
    return unique


def load_clips(paths: Iterable[Path]) -> Iterable[Clip]:
    """(path as text, int16 16 kHz samples) for each file, loaded one at a time."""
    for p in paths:
        yield str(p), as_int16(read_wav_16k(p))


def parse_thresholds(text: str) -> List[float]:
    values = [float(v) for v in text.split(",") if v.strip()]
    if not values or any(not 0.0 <= v <= 1.0 for v in values):
        raise argparse.ArgumentTypeError(f"thresholds must be comma separated numbers in [0, 1], got {text!r}")
    return sorted(set(values))


def _fmt(v: Optional[float], spec: str) -> str:
    return "-" if v is None else format(v, spec)


def table(result: Optional[Dict], e4: Optional[Dict]) -> str:
    """Compact text table: threshold, recall, FA, FA/h (and the E4 session's hits, FA, FA/h with --e4)."""
    rows = (result or {}).get("thresholds") or []
    e4_rows = {r["threshold"]: r for r in (e4 or {}).get("thresholds", [])}
    ths = sorted({r["threshold"] for r in rows} | set(e4_rows))
    by_th = {r["threshold"]: r for r in rows}
    lines = []
    if result:
        lines.append(f"{result['positives']} positive clips; {result['negative_files']} negative files, "
                     f"{result['negative_hours']:.2f} h")
    if e4:
        lines.append(f"E4 session: {e4['positives']} takes, {e4['non_wake_seconds']:.0f} s without a take")
    head = f"{'threshold':>9}  {'recall':>16}  {'FA':>5}  {'FA/h':>7}"
    if e4:
        head += f"  {'E4 hits':>7}  {'E4 FA':>5}  {'E4 FA/h':>7}"
    lines.append(head)
    for t in ths:
        r = by_th.get(t)
        line = f"{t:>9.2f}  "
        if r:
            rec = f"{_fmt(r['recall'], '.3f')} ({r['hits']}/{r['positives']})"
            line += f"{rec:>16}  {r['false_alarms']:>5}  {_fmt(r['fa_per_hour'], '7.2f'):>7}"
        else:
            line += f"{'-':>16}  {'-':>5}  {'-':>7}"
        if e4:
            q = e4_rows.get(t)
            line += (f"  {q['hits']:>3}/{q['positives']:<3}  {len(q['false_alarms']):>5}  "
                     f"{_fmt(q['fa_per_hour'], '7.1f'):>7}") if q else f"  {'-':>7}  {'-':>5}  {'-':>7}"
        lines.append(line)
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None, scorer_factory: Optional[Callable[[], Scorer]] = None) -> int:
    p = argparse.ArgumentParser(prog="python3 -m near_wake.evaluate", description=__doc__.splitlines()[0])
    p.add_argument("--model", help="openWakeWord .onnx model")
    p.add_argument("--melspec", help="melspectrogram.onnx (default: the one inside the openwakeword package)")
    p.add_argument("--embedding", help="embedding_model.onnx (default: the one inside the openwakeword package)")
    p.add_argument("--pos", nargs="+", default=[], metavar="DIR_OR_GLOB", help="positive clips")
    p.add_argument("--neg", nargs="+", default=[], metavar="FILE_OR_DIR", help="negative audio")
    p.add_argument("--e4", nargs="?", const=str(DEFAULT_E4_DIR), metavar="DIR",
                   help=f"also score the phase 0 E4 session (default dir {DEFAULT_E4_DIR})")
    p.add_argument("--thresholds", type=parse_thresholds, default=list(DEFAULT_THRESHOLDS))
    p.add_argument("--cooldown", type=float, default=DEFAULT_COOLDOWN_S, help="seconds")
    p.add_argument("--json", type=Path, help="write every number (missed files, false alarm times) here")
    args = p.parse_args(argv)
    if not (args.pos or args.neg or args.e4):
        p.error("nothing to score: give --pos, --neg or --e4")
    if scorer_factory is None:
        if not args.model:
            p.error("--model is required")
        scorer_factory = lambda: OwwScorer(args.model, args.melspec, args.embedding)  # noqa: E731
    pos, neg = expand_paths(args.pos), expand_paths(args.neg)
    e4_files = load_e4(args.e4) if args.e4 else None
    scorer = scorer_factory()
    result = None
    if pos or neg:
        result = evaluate(lambda: scorer, load_clips(pos), load_clips(neg), args.thresholds, args.cooldown)
    e4 = None
    if e4_files:
        session = as_int16(read_wav_16k(e4_files["wav"]))
        e4 = evaluate_session(scorer, session, e4_files["spans"], args.thresholds, args.cooldown)
        e4.update(positives=len(e4_files["spans"]), wav=str(e4_files["wav"]))
    print(table(result, e4))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({"model": args.model, "thresholds": args.thresholds,
                                         "cooldown_s": args.cooldown, "clips": result, "e4": e4}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
