"""The near-voice TCP server: one listen at a time, events broadcast to every connected app.

Audio path: mic -> FrameHub -> on_frame (ring buffer always; VAD + Segmenter only while listening) -> STT in a worker
thread -> "final". VAD and STT do not run outside a listen. Audio never leaves RAM, except the utterance itself when a
cloud STT engine is configured (harness.py).

Wake word (wake.py, optional): a hit sends "wake"; the app answers with an ordinary "listen", and a listen that comes
within [wake_listen_s] starts right after the wake word instead of 0.5 s back, so "Hey Near" is not transcribed.
"""

from __future__ import annotations

import asyncio
import logging
import time
from concurrent.futures import Executor, ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Callable, List, Optional, Set, Tuple

from . import protocol as p
from .audio import Frame, RingBuffer, frames_for, level_db
from .chime import Chimes
from .segmenter import NoSpeech, Result, Segmenter, SegmenterConfig, Utterance
from .stt import SttEngine
from .vad import Vad
from .wake import WakeHit

log = logging.getLogger("near_voice.server")

# Peak below this for a whole no-speech wait means the mic gave digital silence: report no_audio, not no_speech.
# The board mic's noise gate does not output zeros: a quiet office reads peak 24-47 (about -75 dBFS RMS).
NO_AUDIO_PEAK = 8
MAX_CLIENT_BUFFER = 1 << 20


@dataclass
class _Listen:
    id: str
    seg: Segmenter
    levels: List[bytes] = field(default_factory=list)
    watchdog: Optional[asyncio.TimerHandle] = None


class VoiceServer:
    def __init__(
        self,
        vad: Vad,
        stt: SttEngine,
        chimes: Optional[Chimes] = None,
        *,
        config: SegmenterConfig = SegmenterConfig(),
        preroll_s: float = 0.5,
        ring_s: float = 2.0,
        level_every: int = 3,
        no_audio_grace_s: float = 1.0,
        wake_listen_s: float = 1.5,
        executor: Optional[Executor] = None,
    ) -> None:
        self.vad = vad
        self.stt = stt
        self.chimes = chimes
        self.config = config
        self.ring = RingBuffer(frames_for(max(ring_s, preroll_s)))
        self._preroll = frames_for(preroll_s)
        self._level_every = max(1, level_every)
        self._watchdog_s = config.no_speech_s + no_audio_grace_s
        self._executor = executor or ThreadPoolExecutor(max_workers=1, thread_name_prefix="stt")
        self._own_executor = executor is None
        self._listen: Optional[_Listen] = None
        self._awaiting: Optional[str] = None  # id whose "final" the app still wants
        self._clients: Set[asyncio.StreamWriter] = set()
        self._tasks: Set[asyncio.Task] = set()
        self._server: Optional[asyncio.AbstractServer] = None
        # Called with the listen id before listening starts, e.g. to stop a sound that is playing.
        self.before_listen: List[Callable[[str], None]] = []
        # Wake word: the spotter's name when one runs (goes into "ready"), the app's on/off switch, and the frame a
        # listen should start from after the last hit (with when it was heard).
        self.wake_engine: Optional[str] = None
        self.wake_on = True
        self._wake_listen_s = wake_listen_s
        self._wake: Optional[Tuple[int, float]] = None

    # ---- lifecycle

    async def start(self, host: str = "127.0.0.1", port: int = 8781) -> int:
        self._server = await asyncio.start_server(self._serve_client, host, port)
        bound = self._server.sockets[0].getsockname()[1]
        log.info("listening on %s:%s", host, bound)
        return bound

    async def close(self) -> None:
        self.cancel()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
        clients, self._clients = list(self._clients), set()
        for w in clients:
            await _close_writer(w)
        for t in list(self._tasks):
            t.cancel()
        if self._own_executor and isinstance(self._executor, ThreadPoolExecutor):
            self._executor.shutdown(wait=False)

    # ---- audio

    def on_frame(self, frame: Frame) -> None:
        """FrameHub consumer: every captured frame comes through here."""
        self.ring.push(frame)
        listen = self._listen
        if listen is None:
            return
        result = listen.seg.feed(frame.pcm, self.vad.is_speech(frame.pcm))
        listen.levels.append(frame.pcm)
        if len(listen.levels) >= self._level_every:
            self._send(p.level(level_db(b"".join(listen.levels))))
            listen.levels.clear()
        if result is not None:
            self._end(listen, result)

    # ---- wake word

    def wake_wanted(self) -> bool:
        """Whether the spotter should be fed now: a spotter runs, an app is connected and wants it, and no listen is
        open or waiting for its words (the app is already listening, so a wake word would mean nothing)."""
        return (self.wake_engine is not None and self.wake_on and bool(self._clients)
                and self._listen is None and self._awaiting is None)

    def on_wake(self, hit: WakeHit) -> None:
        """The spotter heard the wake word (called on the event loop)."""
        if not self.wake_wanted():
            log.info("wake %s at frame %d: ignored, not wanted now", hit.keyword, hit.index)
            return
        self._wake = (hit.index + 1, asyncio.get_running_loop().time())
        log.info("wake %s at frame %d", hit.keyword, hit.index)
        self._send(p.wake(hit.keyword))

    def _take_wake(self) -> Optional[int]:
        """The frame a listen starts from when it answers a recent wake word, else None (normal pre-roll)."""
        wake, self._wake = self._wake, None
        if wake is None:
            return None
        index, at = wake
        if asyncio.get_running_loop().time() - at > self._wake_listen_s:
            return None
        return index

    # ---- commands

    def begin_listen(self, id_: str, from_index: Optional[int] = None) -> None:
        """Starts a listen. The utterance may begin [preroll_s] before now, or at frame [from_index] when given
        (e.g. right after a wake word, so the wake word itself is not transcribed)."""
        for hook in self.before_listen:
            try:
                hook(id_)
            except Exception:  # noqa: BLE001
                log.exception("before_listen hook failed")
        self._stop_listen()
        self.vad.reset()
        listen = _Listen(id_, Segmenter(self.config))
        self._listen = listen
        self._awaiting = id_
        self._send(p.listening(id_))
        pre = self.ring.since(from_index) if from_index is not None else self.ring.last(self._preroll)
        log.info("listen %s: start (%d frames before)", id_, len(pre))
        for f in pre:
            result = listen.seg.feed(f.pcm, self.vad.is_speech(f.pcm), live=False)
            if result is not None:
                self._end(listen, result)
                return
        listen.watchdog = asyncio.get_running_loop().call_later(self._watchdog_s, self._check_mic, listen)

    def cancel(self) -> None:
        """Stops listening and drops any pending result: the app has moved on."""
        if self._listen is not None or self._awaiting is not None:
            log.info("listen %s: cancelled", self._awaiting)
        self._stop_listen()
        self._awaiting = None

    def finish(self) -> None:
        """The user tapped to say they are done: transcribe what was said so far, or report no speech.
        Ignored when not listening (already transcribing, or idle)."""
        listen = self._listen
        if listen is None:
            return
        log.info("listen %s: finished by the user after %d frames", listen.id, listen.seg.live_frames)
        result = listen.seg.finish()
        if result is not None:
            self._end(listen, result)

    def handle_line(self, line: bytes, sender: Optional[asyncio.StreamWriter] = None) -> None:
        try:
            cmd = p.decode_command(line)
        except p.ProtocolError as e:
            log.warning("bad command %r: %s", line[:200], e)
            # Only to the sender: an "error" makes the app drop its listen, and the bad line may come from a dev tool.
            if sender is not None and not sender.is_closing():
                sender.write(p.error(f"bad command: {e}"))
            return
        if isinstance(cmd, p.Listen):
            self.begin_listen(cmd.id, self._take_wake())
        elif isinstance(cmd, p.Cancel):
            self.cancel()
        elif isinstance(cmd, p.Finish):
            self.finish()
        elif isinstance(cmd, p.Chime):
            if self.chimes is not None:
                self._spawn(self.chimes.play(cmd.name))
        elif isinstance(cmd, p.Wake):
            if cmd.on != self.wake_on:
                log.info("wake word %s by the app", "on" if cmd.on else "off")
            self.wake_on = cmd.on
            if not cmd.on:
                self._wake = None
        else:
            log.info("ignored unknown command %r", line[:200])

    # ---- internals

    def _stop_listen(self) -> None:
        listen, self._listen = self._listen, None
        if listen is not None and listen.watchdog is not None:
            listen.watchdog.cancel()

    def _check_mic(self, listen: _Listen) -> None:
        """Runs [no_speech_s + grace] after a listen starts. If the mic delivered far too few frames by then, the
        Segmenter cannot time out by itself: report no_audio."""
        if self._listen is not listen or listen.seg.speaking:
            return
        expected = frames_for(self.config.no_speech_s)
        if listen.seg.live_frames < expected // 2:
            log.error("mic: only %d frames in %.1f s", listen.seg.live_frames, self._watchdog_s)
            self._end(listen, NoSpeech(0))

    def _end(self, listen: _Listen, result: Result) -> None:
        self._stop_listen()
        if isinstance(result, NoSpeech):
            self._awaiting = None
            reason = p.NO_AUDIO if result.peak < NO_AUDIO_PEAK else p.NO_SPEECH
            log.info("listen %s: %s (peak %d)", listen.id, reason, result.peak)
            self._send(p.timeout(listen.id, reason))
            return
        self._send(p.processing(listen.id))
        self._spawn(self._transcribe(listen.id, result))

    async def _transcribe(self, id_: str, utt: Utterance) -> None:
        loop = asyncio.get_running_loop()
        t0 = time.perf_counter()
        try:
            text, engine = await loop.run_in_executor(self._executor, self._run_stt, utt.pcm)
        except Exception as e:  # noqa: BLE001
            log.exception("stt failed")
            if self._awaiting == id_:
                self._awaiting = None
                self._send(p.error(f"stt: {e}"))
            return
        stt_ms = int((time.perf_counter() - t0) * 1000)
        # The transcript stays in the local log only (spec section 9: used to improve the parser).
        log.info("listen %s: %r (audio %d ms%s, stt %d ms)", id_, text, utt.audio_ms,
                 ", cut at max" if utt.forced else "", stt_ms)
        if self._awaiting != id_:
            log.info("listen %s: dropped, cancelled or superseded", id_)
            return
        self._awaiting = None
        self._send(p.final(id_, text, utt.audio_ms, stt_ms, engine))

    def _run_stt(self, pcm: bytes) -> Tuple[str, str]:
        """On the STT thread: the words, and the engine that gave them (CloudFirstStt says which one answered)."""
        text = self.stt.transcribe(pcm)
        return text, getattr(self.stt, "last_engine", None) or self.stt.name

    def _spawn(self, coro) -> None:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def _send(self, data: bytes) -> None:
        for w in list(self._clients):
            if w.is_closing():
                self._clients.discard(w)
                continue
            if w.transport.get_write_buffer_size() > MAX_CLIENT_BUFFER:
                log.warning("client not reading, closing it")
                self._clients.discard(w)
                w.close()
                continue
            w.write(data)

    async def _serve_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._clients.add(writer)
        log.info("app connected (%d)", len(self._clients))
        writer.write(p.ready(self.stt.model, self.stt.name, wake=self.wake_engine or "off"))
        try:
            while True:
                try:
                    line = await reader.readline()
                except ValueError:  # longer than the stream limit
                    log.warning("line too long, closing client")
                    break
                except ConnectionError:
                    break
                if not line:
                    break
                if line.strip():
                    self.handle_line(line, writer)
        finally:
            self._clients.discard(writer)
            log.info("app disconnected (%d left)", len(self._clients))
            if not self._clients:
                self.cancel()
            await _close_writer(writer)


async def _close_writer(writer: asyncio.StreamWriter) -> None:
    if not writer.is_closing():
        writer.close()
    try:
        await writer.wait_closed()
    except (ConnectionError, OSError):
        pass
