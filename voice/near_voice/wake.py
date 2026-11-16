"""Wake word ("Hey Near") with sherpa-onnx's open-vocabulary keyword spotter. A trial, off unless `--wake kws`.

Phase 0 E5 measured this model on the user's voice: the best setting (zh-en 3M, ARPAbet `HH EY1 N IH1 R`, threshold
0.15, score 2) caught 2 of 12 "Hey Near" and raised no false alarm in 95 s of commands. So this runs the whole path
(wake -> listen -> command) on the board; it is not a finished wake word (that needs a trained model, plan step C3).

The spotter runs in a thread of its own: a decode (about 8% of an A76 core in total) never holds up the mic, the
event loop or the protocol. Frames are queued for it only while the server wants spotting: an app is connected and has
not turned it off, and no listen is open or waiting for its words. The spotter may lag behind the queue, so a hit can
come in after spotting stopped being wanted; the server ignores it then. Each time feeding starts again, the frames
still queued from before the gap are dropped and the stream starts fresh, so a keyword is never pieced together across
a gap.
"""

from __future__ import annotations

import glob
import logging
import os
import queue
import threading
from dataclasses import dataclass
from typing import Callable, Optional, Protocol

from .audio import SAMPLE_RATE, Frame, frames_for

log = logging.getLogger("near_voice.wake")

DEFAULT_MODEL = "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20"
KEYWORDS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "keywords")
DEFAULT_KEYWORDS = os.path.join(KEYWORDS_DIR, "hey-near-zhen.txt")
DEFAULT_THRESHOLD = 0.15
DEFAULT_SCORE = 2.0

# E5's files: int8 encoder and joiner, float decoder, the 16-frame chunk model.
_PATTERNS = {
    "encoder": ["encoder*chunk-16*.int8.onnx", "encoder*.int8.onnx", "encoder*.onnx"],
    "decoder": ["decoder*chunk-16*.onnx", "decoder*.onnx"],
    "joiner": ["joiner*chunk-16*.int8.onnx", "joiner*.int8.onnx", "joiner*.onnx"],
    "tokens": ["tokens.txt"],
}


def pick_kws_files(model_dir: str) -> dict:
    """Paths of encoder, decoder (never the int8 one, as in E5), joiner and tokens in a sherpa-onnx KWS directory."""
    found = {}
    for key, patterns in _PATTERNS.items():
        for p in patterns:
            hits = sorted(h for h in glob.glob(os.path.join(model_dir, p))
                          if key != "decoder" or ".int8." not in os.path.basename(h))
            if hits:
                found[key] = hits[0]
                break
        else:
            raise FileNotFoundError(f"{model_dir}: no {key} file ({', '.join(patterns)})")
    return found


@dataclass(frozen=True)
class WakeHit:
    keyword: str
    index: int  # the frame being fed when the keyword was spotted; the command starts with the next one


class Spotter(Protocol):
    name: str

    def accept(self, pcm: bytes) -> Optional[str]:
        """Feeds one frame; the keyword spotted in the audio so far, or None."""

    def reset(self) -> None:
        """Forgets the audio fed so far."""


class SherpaKws:
    name = "sherpa-kws"

    def __init__(self, model_dir: str, keywords_file: str = DEFAULT_KEYWORDS, *,
                 threshold: float = DEFAULT_THRESHOLD, score: float = DEFAULT_SCORE, threads: int = 1) -> None:
        import sherpa_onnx as so

        if not os.path.isfile(keywords_file):
            raise FileNotFoundError(f"no keywords file {keywords_file}")
        files = pick_kws_files(model_dir)
        self.model = os.path.basename(os.path.normpath(model_dir))
        self._kws = so.KeywordSpotter(keywords_file=keywords_file, num_threads=threads, keywords_threshold=threshold,
                                      keywords_score=score, **files)
        self._stream = self._kws.create_stream()

    def accept(self, pcm: bytes) -> Optional[str]:
        import numpy as np

        x = np.frombuffer(pcm[: len(pcm) - len(pcm) % 2], dtype="<i2").astype(np.float32) / 32768.0
        self._stream.accept_waveform(SAMPLE_RATE, x)
        hit = None
        while self._kws.is_ready(self._stream):
            self._kws.decode_stream(self._stream)
            keyword = self._kws.get_result(self._stream)
            if keyword:
                hit = keyword
                self._kws.reset_stream(self._stream)
        return hit

    def reset(self) -> None:
        self._stream = self._kws.create_stream()


_RESET = object()
_STOP = object()


class WakeWorker:
    """FrameHub consumer that feeds a Spotter in its own thread and reports hits through [post].

    [active] (called on the frame's thread) says whether frames should be spotted right now. [post] runs [on_hit] where
    it belongs, e.g. `loop.call_soon_threadsafe`. After a hit, [cooldown_s] of audio is skipped, so one "Hey Near"
    never fires twice.
    """

    def __init__(self, spotter: Spotter, active: Callable[[], bool], on_hit: Callable[[WakeHit], None],
                 post: Callable[..., object], *, cooldown_s: float = 2.0, queue_s: float = 2.0) -> None:
        self.spotter = spotter
        self.active = active
        self.on_hit = on_hit
        self.post = post
        self._cooldown = frames_for(cooldown_s)
        self._queue: "queue.Queue[object]" = queue.Queue(maxsize=frames_for(queue_s))
        self._feeding = False
        self._skip_until = -1
        self.dropped = 0
        self.hits = 0
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="wake", daemon=True)
        self._thread.start()

    def stop(self, timeout: float = 2.0) -> None:
        if self._thread is None:
            return
        while True:  # make room for the stop marker even when the spotter is far behind
            try:
                self._queue.put_nowait(_STOP)
                break
            except queue.Full:
                try:
                    self._queue.get_nowait()
                except queue.Empty:
                    pass
        self._thread.join(timeout)
        self._thread = None

    def on_frame(self, frame: Frame) -> None:
        if not self.active():
            self._feeding = False
            return
        if not self._feeding:
            self._feeding = True
            self._restart()
        self._put(frame)

    def _restart(self) -> None:
        """Feeding starts (again, after a gap). The frames still queued from before it are of no use, so they go first:
        the reset marker then always fits (only on_frame puts items, apart from stop())."""
        stale = 0
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                break
            if item is _STOP:  # stop() is under way: keep its marker, nothing more will be spotted
                self._queue.put_nowait(_STOP)
                return
            stale += item is not _RESET
        if stale:
            log.debug("wake: %d frames from before the gap dropped", stale)
        try:
            self._queue.put_nowait(_RESET)
        except queue.Full:  # only when stop() put its marker in meanwhile: nothing more will be spotted
            pass

    def _put(self, item: object) -> None:
        try:
            self._queue.put_nowait(item)
        except queue.Full:
            # The spotter is more than [queue_s] behind (CPU starved): skip audio rather than fall further behind.
            self.dropped += 1
            if self.dropped == 1 or self.dropped % 500 == 0:
                log.warning("wake: spotter behind, %d frames dropped", self.dropped)

    def _run(self) -> None:
        while True:
            item = self._queue.get()
            if item is _STOP:
                return
            self.handle(item)

    def handle(self, item: object) -> None:
        """One queue item, on the spotter's thread (tests call it directly)."""
        if item is _RESET:
            self.spotter.reset()
            return
        assert isinstance(item, Frame)
        if item.index < self._skip_until:
            return
        try:
            keyword = self.spotter.accept(item.pcm)
        except Exception:  # noqa: BLE001 - a broken decode must not end spotting for good
            log.exception("wake: spotter failed")
            return
        if not keyword:
            return
        self.hits += 1
        self._skip_until = item.index + 1 + self._cooldown
        self.spotter.reset()
        self.post(self.on_hit, WakeHit(keyword.strip(), item.index))
