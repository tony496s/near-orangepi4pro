"""Voice activity detection: one yes/no per 32 ms frame."""

from __future__ import annotations

from typing import Protocol

from .audio import FRAME_BYTES, FRAME_MS, SAMPLE_RATE


class Vad(Protocol):
    def reset(self) -> None: ...

    def is_speech(self, pcm: bytes) -> bool: ...


class SileroVad:
    """Silero VAD through sherpa-onnx (measured at E4).

    Debouncing is set to a single window, close to the raw per-window decision: Segmenter applies the 0.25 s / 0.6 s
    rules itself. (sherpa-onnx rejects 0 for these.) About 0.44 ms per frame on one A76 core.
    """

    def __init__(self, model_path: str, threshold: float = 0.5) -> None:
        import sherpa_onnx as so

        cfg = so.VadModelConfig()
        cfg.silero_vad.model = model_path
        cfg.silero_vad.threshold = threshold
        cfg.silero_vad.min_silence_duration = FRAME_MS / 1000
        cfg.silero_vad.min_speech_duration = FRAME_MS / 1000
        cfg.sample_rate = SAMPLE_RATE
        cfg.num_threads = 1
        if not cfg.validate():
            raise ValueError(f"bad VAD config for {model_path}")
        self._model = so.VadModel.create(cfg)
        if self._model.window_size() * 2 != FRAME_BYTES:
            raise ValueError(f"VAD window {self._model.window_size()} does not match frame size")

    def reset(self) -> None:
        self._model.reset()

    def is_speech(self, pcm: bytes) -> bool:
        import numpy as np

        # sherpa-onnx aborts the process on a short window, so never pass one.
        if len(pcm) != FRAME_BYTES:
            raise ValueError(f"frame is {len(pcm)} bytes, need {FRAME_BYTES}")
        x = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        return bool(self._model.is_speech(x))
