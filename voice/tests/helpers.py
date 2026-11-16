"""Made-up audio and fake engines, so the tests need neither a mic nor a model."""

from __future__ import annotations

import struct
import threading
from typing import List, Optional

from near_voice.audio import FRAME_SAMPLES, level_db


def frame(value: int) -> bytes:
    """One frame where every sample is [value]."""
    return struct.pack(f"<{FRAME_SAMPLES}h", *([value] * FRAME_SAMPLES))


def tone(amplitude: int) -> bytes:
    """One frame of a square wave at [amplitude] (RMS == amplitude)."""
    return struct.pack(f"<{FRAME_SAMPLES}h", *([amplitude, -amplitude] * (FRAME_SAMPLES // 2)))


SILENCE = frame(0)
LOUD = tone(8000)  # about -12 dBFS: speech for EnergyVad
HISS = tone(100)  # about -50 dBFS: a quiet room, not speech, but a working mic


def first_sample(pcm: bytes) -> int:
    return struct.unpack_from("<h", pcm)[0]


class EnergyVad:
    """Speech when the frame is louder than [threshold_db]."""

    def __init__(self, threshold_db: float = -40.0) -> None:
        self.threshold_db = threshold_db
        self.resets = 0

    def reset(self) -> None:
        self.resets += 1

    def is_speech(self, pcm: bytes) -> bool:
        return level_db(pcm) > self.threshold_db


class FakeStt:
    name = "fake"
    model = "fake-model"

    def __init__(self, text: str = "ĐẶT HẸN GIỜ MƯỜI LĂM PHÚT", block: bool = False,
                 fail: Optional[Exception] = None) -> None:
        self.text = text
        self.fail = fail
        self.calls: List[bytes] = []
        self.release = threading.Event()
        if not block:
            self.release.set()
        self.finished = threading.Event()

    def transcribe(self, pcm: bytes) -> str:
        self.calls.append(pcm)
        self.release.wait(5)
        self.finished.set()
        if self.fail is not None:
            raise self.fail
        return self.text


class FakeChimes:
    def __init__(self) -> None:
        self.played: List[str] = []
        self.stops = 0

    async def play(self, name: str) -> None:
        self.played.append(name)

    def stop(self) -> None:
        self.stops += 1
