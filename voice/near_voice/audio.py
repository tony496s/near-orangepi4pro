"""Audio frames: capture, fan-out, ring buffer and small PCM helpers.

Everything is 16 kHz mono signed 16-bit little-endian PCM, cut into frames of 512 samples (32 ms): one Silero VAD
window. Audio only lives in RAM; nothing here writes to disk.
"""

from __future__ import annotations

import asyncio
import logging
import math
import struct
import sys
import wave
from array import array
from collections import deque
from dataclasses import dataclass
from typing import Callable, Deque, List, Optional, Sequence

log = logging.getLogger("near_voice.audio")

SAMPLE_RATE = 16000
FRAME_SAMPLES = 512
FRAME_BYTES = FRAME_SAMPLES * 2
FRAME_MS = FRAME_SAMPLES * 1000 / SAMPLE_RATE  # 32.0

BOARD_MIC = "plughw:CARD=Device,DEV=0"
MAC_MIC = ":0"

SILENCE_DB = -100.0


def frames_for(seconds: float) -> int:
    """Number of whole frames covering [seconds] (at least one)."""
    return max(1, math.ceil(seconds * 1000 / FRAME_MS - 1e-9))


@dataclass(frozen=True)
class Frame:
    index: int  # counts up from 0 since the service started, across capture restarts
    pcm: bytes  # FRAME_BYTES


def samples(pcm: bytes) -> array:
    a = array("h")
    a.frombytes(pcm[: len(pcm) - len(pcm) % 2])
    if sys.byteorder == "big":
        a.byteswap()
    return a


def peak(pcm: bytes) -> int:
    """Largest absolute sample value (0..32768)."""
    s = samples(pcm)
    return max((abs(v) for v in s), default=0)


def level_db(pcm: bytes) -> float:
    """RMS level in dBFS, SILENCE_DB for digital silence."""
    s = samples(pcm)
    if not s:
        return SILENCE_DB
    rms = math.sqrt(sum(v * v for v in s) / len(s))
    if rms <= 0:
        return SILENCE_DB
    return max(SILENCE_DB, 20 * math.log10(rms / 32768))


def wav_bytes(pcm: bytes, rate: int = SAMPLE_RATE, channels: int = 1) -> bytes:
    """A self-describing 44-byte-header WAV around 16-bit PCM."""
    data = pcm[: len(pcm) - len(pcm) % 2]
    block = channels * 2
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(data), b"WAVE",
        b"fmt ", 16, 1, channels, rate, rate * block, block, 16,
        b"data", len(data),
    )
    return header + data


def read_wav(path: str) -> bytes:
    """PCM of a 16 kHz mono 16-bit WAV file; ValueError for any other format."""
    with wave.open(path, "rb") as w:
        if w.getframerate() != SAMPLE_RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(f"{path}: need 16 kHz mono 16-bit, got {w.getframerate()} Hz "
                             f"{w.getnchannels()} ch {w.getsampwidth() * 8}-bit")
        return w.readframes(w.getnframes())


class RingBuffer:
    """The last [capacity] frames, in RAM only. Gives pre-roll to a listen, or audio from a given frame index on."""

    def __init__(self, capacity: int) -> None:
        if capacity < 1:
            raise ValueError("capacity must be >= 1")
        self._frames: Deque[Frame] = deque(maxlen=capacity)

    def push(self, frame: Frame) -> None:
        self._frames.append(frame)

    def last(self, n: int) -> List[Frame]:
        if n <= 0:
            return []
        return list(self._frames)[-n:]

    def since(self, index: int) -> List[Frame]:
        """Frames with index >= [index] still held (older ones have been dropped)."""
        return [f for f in self._frames if f.index >= index]

    @property
    def latest(self) -> Optional[int]:
        return self._frames[-1].index if self._frames else None

    def __len__(self) -> int:
        return len(self._frames)


FrameConsumer = Callable[[Frame], None]


class FrameHub:
    """The one place captured audio fans out from. Consumers run in order; one failing does not stop the others."""

    def __init__(self) -> None:
        self._consumers: List[FrameConsumer] = []
        self._next = 0

    def add(self, consumer: FrameConsumer) -> None:
        self._consumers.append(consumer)

    def remove(self, consumer: FrameConsumer) -> None:
        if consumer in self._consumers:
            self._consumers.remove(consumer)

    def push(self, pcm: bytes) -> Frame:
        frame = Frame(self._next, pcm)
        self._next += 1
        for c in list(self._consumers):
            try:
                c(frame)
            except Exception:  # noqa: BLE001 - one broken consumer must not stop the mic
                log.exception("frame consumer failed")
        return frame


def mic_command(device: Optional[str] = None, platform: str = sys.platform) -> List[str]:
    """Recorder that writes raw 16 kHz mono s16le to stdout: arecord on the board, ffmpeg on a Mac."""
    if platform == "darwin":
        return ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-i", device or MAC_MIC,
                "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "s16le", "-"]
    # plughw converts the mic's 48 kHz stereo to what we ask for.
    return ["arecord", "-q", "-D", device or BOARD_MIC, "-f", "S16_LE", "-r", str(SAMPLE_RATE), "-c", "1", "-t", "raw"]


class Capture:
    """Runs a recorder command and pushes its output, frame by frame, into a hub. Restarts it when it exits."""

    def __init__(self, command: Sequence[str], hub: FrameHub, restart_delay: float = 2.0) -> None:
        self.command = list(command)
        self.hub = hub
        self.restart_delay = restart_delay
        self.restarts = 0
        self._proc: Optional[asyncio.subprocess.Process] = None
        self._stopped = False

    async def run(self) -> None:
        while not self._stopped:
            try:
                self._proc = await asyncio.create_subprocess_exec(
                    *self.command, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE)
            except OSError as e:
                log.error("mic: cannot start %s: %s", self.command[0], e)
            else:
                log.info("mic: %s", " ".join(self.command))
                await self._pump(self._proc)
                code = await self._proc.wait()
                if self._stopped:
                    break
                log.error("mic: recorder exited with code %s", code)
            self.restarts += 1
            await asyncio.sleep(self.restart_delay)

    async def _pump(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stdout is not None
        while True:
            try:
                chunk = await proc.stdout.readexactly(FRAME_BYTES)
            except asyncio.IncompleteReadError:
                return
            self.hub.push(chunk)

    def stop(self) -> None:
        self._stopped = True
        if self._proc is not None and self._proc.returncode is None:
            try:
                self._proc.terminate()
            except ProcessLookupError:
                pass


class WavSource:
    """Dev stand-in for the mic: emits silence in real time, and the queued WAV when [play] is called.

    Used to test the whole service on the board without speaking (e.g. play a recorded command on each listen).
    """

    def __init__(self, pcm: bytes, hub: FrameHub, realtime: bool = True) -> None:
        self.pcm = pcm
        self.hub = hub
        self.realtime = realtime
        self._queue: Deque[bytes] = deque()
        self._stopped = False

    def play(self) -> None:
        self._queue.clear()
        for i in range(0, len(self.pcm), FRAME_BYTES):
            chunk = self.pcm[i:i + FRAME_BYTES]
            self._queue.append(chunk.ljust(FRAME_BYTES, b"\0"))

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        start = loop.time()
        n = 0
        silence = bytes(FRAME_BYTES)
        while not self._stopped:
            self.hub.push(self._queue.popleft() if self._queue else silence)
            n += 1
            if self.realtime:
                await asyncio.sleep(max(0.0, start + n * FRAME_MS / 1000 - loop.time()))
            else:
                await asyncio.sleep(0)

    def stop(self) -> None:
        self._stopped = True
