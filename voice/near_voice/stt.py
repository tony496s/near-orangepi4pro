"""Speech to text engines: the local Zipformer-vi, and CloudFirstStt that puts a cloud engine (harness.py) in front of
it with the local one as the fallback."""

from __future__ import annotations

import glob
import logging
import os
import time
from concurrent.futures import Executor, ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from typing import Optional, Protocol

from .audio import SAMPLE_RATE

DEFAULT_MODEL = "sherpa-onnx-zipformer-vi-30M-int8-2026-02-09"

# First pattern that matches wins (same order as phase0/stt/run_stt.py), so int8 files are preferred.
_PATTERNS = {
    "encoder": ["*encoder*.int8.onnx", "*encoder*.onnx"],
    "decoder": ["*decoder*.int8.onnx", "*decoder*.onnx"],
    "joiner": ["*joiner*.int8.onnx", "*joiner*.onnx"],
    "tokens": ["tokens.txt", "*tokens.txt"],
}


log = logging.getLogger("near_voice.stt")


class SttEngine(Protocol):
    name: str  # goes into the "engine" field of "final" (an engine may set last_engine to say which one answered)
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


class CloudFirstStt:
    """The cloud engine's words when they come in time, the local engine's otherwise.

    Both start at once: the local decode (about 0.2 s on the A76) runs while the cloud request is on the network, so
    a cloud failure or timeout costs no extra decode. The cloud answer is used when it arrives within [timeout_s] of
    the start and is not empty; anything else (no sign-in, network down, 429 over the account's voice quota, a 5xx)
    falls back to the local words. [last_engine] says which one answered, for the "engine" field of "final".

    Both transcripts go to the local log side by side (spec section 9), which is how the two get compared.
    """

    def __init__(self, cloud: SttEngine, local: SttEngine, timeout_s: float = 3.0,
                 executor: Optional[Executor] = None) -> None:
        self.cloud = cloud
        self.local = local
        self.timeout_s = timeout_s
        self.name = cloud.name
        self.model = f"{cloud.model}+{local.model}"
        self.last_engine = local.name
        # Two workers: a cloud call stuck until its own HTTP timeout must not queue the next sentence behind it.
        self._pool = executor or ThreadPoolExecutor(max_workers=2, thread_name_prefix="cloud-stt")

    def transcribe(self, pcm: bytes) -> str:
        t0 = time.perf_counter()
        pending = self._pool.submit(self.cloud.transcribe, pcm)
        local_text = self.local.transcribe(pcm)
        local_ms = int((time.perf_counter() - t0) * 1000)
        cloud_text: Optional[str] = None
        try:
            cloud_text = pending.result(timeout=max(0.0, self.timeout_s - (time.perf_counter() - t0)))
        except FutureTimeout:
            pending.cancel()
            log.warning("cloud stt: no answer within %.1f s, using local", self.timeout_s)
        except Exception as e:  # noqa: BLE001 - any cloud failure means "use the local words"
            log.warning("cloud stt failed (%s: %s), using local", type(e).__name__, e)
        cloud_ms = int((time.perf_counter() - t0) * 1000)
        log.info("stt cloud %r (%d ms) local %r (%d ms)", cloud_text, cloud_ms, local_text, local_ms)
        if cloud_text and cloud_text.strip():
            self.last_engine = self.cloud.name
            return cloud_text.strip()
        self.last_engine = self.local.name
        return local_text

    def warm_up(self) -> None:
        warm = getattr(self.local, "warm_up", None)
        if warm is not None:
            warm()
