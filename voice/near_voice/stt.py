"""Speech to text engines. Only the local Zipformer-vi for now; others plug in behind the same interface."""

from __future__ import annotations

import glob
import os
from typing import Protocol

from .audio import SAMPLE_RATE

DEFAULT_MODEL = "sherpa-onnx-zipformer-vi-30M-int8-2026-02-09"

# First pattern that matches wins (same order as phase0/stt/run_stt.py), so int8 files are preferred.
_PATTERNS = {
    "encoder": ["*encoder*.int8.onnx", "*encoder*.onnx"],
    "decoder": ["*decoder*.int8.onnx", "*decoder*.onnx"],
    "joiner": ["*joiner*.int8.onnx", "*joiner*.onnx"],
    "tokens": ["tokens.txt", "*tokens.txt"],
}


class SttEngine(Protocol):
    name: str  # goes into the "engine" field of "final"
    model: str  # goes into "ready"

    def transcribe(self, pcm: bytes) -> str: ...


def pick_model_files(model_dir: str) -> dict:
    """Paths of encoder, decoder, joiner and tokens inside a sherpa-onnx transducer directory."""
    found = {}
    for key, patterns in _PATTERNS.items():
        for p in patterns:
            hits = sorted(glob.glob(os.path.join(model_dir, p)))
            if hits:
                found[key] = hits[0]
                break
        else:
            raise FileNotFoundError(f"{model_dir}: no {key} file ({', '.join(patterns)})")
    return found


class ZipformerStt:
    name = "zipformer"

    def __init__(self, model_dir: str, threads: int = 2) -> None:
        import sherpa_onnx as so

        files = pick_model_files(model_dir)
        self.model = os.path.basename(os.path.normpath(model_dir))
        self._rec = so.OfflineRecognizer.from_transducer(num_threads=threads, **files)

    def transcribe(self, pcm: bytes) -> str:
        import numpy as np

        x = np.frombuffer(pcm[: len(pcm) - len(pcm) % 2], dtype="<i2").astype(np.float32) / 32768.0
        s = self._rec.create_stream()
        s.accept_waveform(SAMPLE_RATE, x)
        self._rec.decode_stream(s)
        return s.result.text.strip()

    def warm_up(self) -> None:
        """The first decode is slow (allocations); do it at startup, not on the user's first sentence."""
        self.transcribe(bytes(SAMPLE_RATE))  # 0.5 s of silence
