"""Cuts one utterance out of a stream of frames (spec section 6: silence 0.6 s ends it, 8 s max, 4 s with no speech).

A pure state machine: it gets each frame together with the VAD's raw per-window decision and counts time in frames.
No clock, no I/O, so it is tested with made-up frames. The VAD itself runs with minimal debouncing (one window);
all the timing rules live here.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Union

from .audio import FRAME_MS, SAMPLE_RATE, frames_for, peak


@dataclass(frozen=True)
class SegmenterConfig:
    min_speech_s: float = 0.25  # speech must last this long to count (filters clicks)
    min_silence_s: float = 0.6  # this much silence after speech ends the utterance
    max_speech_s: float = 8.0  # the utterance is cut here even if the speaker goes on
    no_speech_s: float = 4.0  # live audio with no speech before giving up
    lead_s: float = 0.3  # audio kept before the detected speech start
    tail_s: float = 0.3  # trailing silence kept after the last speech frame


@dataclass(frozen=True)
class Utterance:
    pcm: bytes
    forced: bool = False  # cut at max_speech_s rather than at a pause

    @property
    def audio_ms(self) -> int:
        return len(self.pcm) // 2 * 1000 // SAMPLE_RATE


@dataclass(frozen=True)
class NoSpeech:
    peak: int  # loudest sample seen; near zero means the mic gave silence, not a quiet room


Result = Union[Utterance, NoSpeech]


class Segmenter:
    def __init__(self, config: SegmenterConfig = SegmenterConfig()) -> None:
        self.config = config
        self._min_speech = frames_for(config.min_speech_s)
        self._min_silence = frames_for(config.min_silence_s)
        self._max_speech = frames_for(config.max_speech_s)
        self._no_speech = frames_for(config.no_speech_s)
        self._lead = round(config.lead_s * 1000 / FRAME_MS)
        self._tail = round(config.tail_s * 1000 / FRAME_MS)
        self._frames: List[bytes] = []
        self._live = 0
        self._run = 0  # consecutive speech frames before speech is confirmed
        self._speech_start: Optional[int] = None
        self._silence = 0
        self._peak = 0
        self.result: Optional[Result] = None

    @property
    def speaking(self) -> bool:
        """Speech has been confirmed (min_speech_s of it)."""
        return self._speech_start is not None

    @property
    def live_frames(self) -> int:
        return self._live

    @property
    def done(self) -> bool:
        return self.result is not None

    def feed(self, pcm: bytes, speech: bool, live: bool = True) -> Optional[Result]:
        """Adds one frame. [live] is False for pre-roll frames, which do not count toward the no-speech timeout.

        Returns the result once, when the utterance ends; None before that and after.
        """
        if self.result is not None:
            return None
        self._frames.append(pcm)
        self._peak = max(self._peak, peak(pcm))
        if live:
            self._live += 1

        if self._speech_start is None:
            self._run = self._run + 1 if speech else 0
            if self._run >= self._min_speech:
                self._speech_start = len(self._frames) - self._run
            elif live and self._live >= self._no_speech and self._run == 0:
                # Never time out in the middle of a word: wait for the run to break first.
                return self._finish(NoSpeech(self._peak))
            return None

        self._silence = 0 if speech else self._silence + 1
        if self._silence >= self._min_silence:
            return self._cut(forced=False)
        if len(self._frames) - self._speech_start >= self._max_speech:
            return self._cut(forced=True)
        return None

    def _cut(self, forced: bool) -> Result:
        assert self._speech_start is not None
        start = max(0, self._speech_start - self._lead)
        end = len(self._frames) - max(0, self._silence - self._tail)
        return self._finish(Utterance(b"".join(self._frames[start:end]), forced=forced))

    def _finish(self, result: Result) -> Result:
        self.result = result
        self._frames = []
        return result
