import asyncio
import io
import os
import struct
import sys
import tempfile
import unittest
import wave

from near_voice import audio
from near_voice.audio import (FRAME_BYTES, Capture, Frame, FrameHub, RingBuffer, WavSource, frames_for, level_db,
                              mic_command, peak, read_wav, wav_bytes)

from .helpers import LOUD, SILENCE, first_sample, frame, tone


class HelpersTest(unittest.TestCase):
    def test_frames_for(self):
        self.assertEqual(frames_for(0.5), 16)
        self.assertEqual(frames_for(0.032), 1)
        self.assertEqual(frames_for(0), 1)
        self.assertEqual(frames_for(4.0), 125)

    def test_peak(self):
        self.assertEqual(peak(SILENCE), 0)
        self.assertEqual(peak(tone(1234)), 1234)
        self.assertEqual(peak(struct.pack("<2h", 5, -32768)), 32768)
        self.assertEqual(peak(b""), 0)

    def test_level_db(self):
        self.assertEqual(level_db(SILENCE), audio.SILENCE_DB)
        self.assertEqual(level_db(b""), audio.SILENCE_DB)
        self.assertAlmostEqual(level_db(tone(32767)), 0.0, places=2)
        self.assertAlmostEqual(level_db(tone(3277)), -20.0, places=1)
        self.assertGreaterEqual(level_db(tone(1)), audio.SILENCE_DB)

    def test_wav_bytes_is_a_valid_self_describing_wav(self):
        pcm = LOUD * 3 + b"\x01"  # odd byte dropped
        data = wav_bytes(pcm)
        self.assertEqual(len(data), 44 + len(LOUD) * 3)
        with wave.open(io.BytesIO(data)) as w:
            self.assertEqual((w.getframerate(), w.getnchannels(), w.getsampwidth()), (16000, 1, 2))
            self.assertEqual(w.readframes(w.getnframes()), LOUD * 3)

    def test_read_wav_round_trip_and_format_check(self):
        with tempfile.TemporaryDirectory() as d:
            good = os.path.join(d, "good.wav")
            with open(good, "wb") as f:
                f.write(wav_bytes(LOUD * 2))
            self.assertEqual(read_wav(good), LOUD * 2)
            bad = os.path.join(d, "bad.wav")
            with open(bad, "wb") as f:
                f.write(wav_bytes(LOUD, rate=48000))
            with self.assertRaises(ValueError):
                read_wav(bad)

    def test_mic_command(self):
        board = mic_command(platform="linux")
        self.assertEqual(board[0], "arecord")
        self.assertIn("plughw:CARD=Device,DEV=0", board)
        self.assertEqual(board[board.index("-r") + 1], "16000")
        self.assertIn("other", mic_command("other", platform="linux"))
        mac = mic_command(platform="darwin")
        self.assertEqual(mac[0], "ffmpeg")
        self.assertEqual(mac[mac.index("-i") + 1], ":0")
        self.assertEqual(mac[-3:], ["-f", "s16le", "-"])


class RingBufferTest(unittest.TestCase):
    def fill(self, ring, count):
        for i in range(count):
            ring.push(Frame(i, frame(i)))

    def test_keeps_only_the_last_frames(self):
        ring = RingBuffer(4)
        self.assertIsNone(ring.latest)
        self.fill(ring, 10)
        self.assertEqual(len(ring), 4)
        self.assertEqual(ring.latest, 9)
        self.assertEqual([f.index for f in ring.last(2)], [8, 9])
        self.assertEqual([f.index for f in ring.last(99)], [6, 7, 8, 9])
        self.assertEqual(ring.last(0), [])

    def test_since_an_index(self):
        ring = RingBuffer(4)
        self.fill(ring, 10)
        self.assertEqual([f.index for f in ring.since(8)], [8, 9])
        self.assertEqual([f.index for f in ring.since(2)], [6, 7, 8, 9])  # older frames are gone
        self.assertEqual(ring.since(10), [])

    def test_capacity_must_be_positive(self):
        with self.assertRaises(ValueError):
            RingBuffer(0)


class FrameHubTest(unittest.TestCase):
    def test_numbers_frames_and_fans_out_in_order(self):
        hub = FrameHub()
        seen = []
        hub.add(lambda f: seen.append(("a", f.index)))
        hub.add(lambda f: seen.append(("b", f.index)))
        hub.push(SILENCE)
        last = hub.push(LOUD)
        self.assertEqual(last, Frame(1, LOUD))
        self.assertEqual(seen, [("a", 0), ("b", 0), ("a", 1), ("b", 1)])

    def test_a_failing_consumer_does_not_stop_the_others(self):
        hub = FrameHub()
        seen = []

        def broken(_):
            raise RuntimeError("boom")

        hub.add(broken)
        hub.add(lambda f: seen.append(f.index))
        with self.assertLogs("near_voice.audio", "ERROR"):
            hub.push(SILENCE)
        self.assertEqual(seen, [0])

    def test_remove(self):
        hub = FrameHub()
        seen = []
        consumer = seen.append
        hub.add(consumer)
        hub.remove(consumer)
        hub.remove(consumer)  # removing twice is harmless
        hub.push(SILENCE)
        self.assertEqual(seen, [])


def emitter(frames: int, extra: bytes = b"") -> list:
    """A recorder stand-in that writes [frames] frames of value 7, then [extra], then exits."""
    code = (f"import sys; sys.stdout.buffer.write(b'\\x07\\x00' * {FRAME_BYTES // 2 * frames} + {extra!r}); "
            "sys.stdout.flush()")
    return [sys.executable, "-c", code]


class CaptureTest(unittest.IsolatedAsyncioTestCase):
    async def wait_for(self, cond, timeout=5.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while not cond():
            if loop.time() > end:
                self.fail("condition not met in time")
            await asyncio.sleep(0.01)

    async def test_pushes_whole_frames_and_restarts_when_the_recorder_exits(self):
        hub = FrameHub()
        got = []
        hub.add(got.append)
        cap = Capture(emitter(3, b"\x01"), hub, restart_delay=0.01)
        task = asyncio.ensure_future(cap.run())
        with self.assertLogs("near_voice.audio", "INFO"):
            await self.wait_for(lambda: len(got) >= 6)
        cap.stop()
        await asyncio.wait_for(task, 5)
        self.assertGreaterEqual(cap.restarts, 1)
        self.assertTrue(all(len(f.pcm) == FRAME_BYTES for f in got))  # the trailing odd byte never became a frame
        self.assertEqual(first_sample(got[0].pcm), 7)
        self.assertEqual([f.index for f in got[:6]], list(range(6)))

    async def test_missing_recorder_is_logged_and_retried(self):
        cap = Capture(["/nonexistent/recorder"], FrameHub(), restart_delay=0.01)
        task = asyncio.ensure_future(cap.run())
        with self.assertLogs("near_voice.audio", "ERROR") as logs:
            await self.wait_for(lambda: cap.restarts >= 2)
        cap.stop()
        await asyncio.wait_for(task, 5)
        self.assertIn("cannot start", logs.output[0])

    async def test_stop_terminates_a_running_recorder(self):
        cap = Capture([sys.executable, "-c", "import time; time.sleep(30)"], FrameHub(), restart_delay=0.01)
        task = asyncio.ensure_future(cap.run())
        await self.wait_for(lambda: cap._proc is not None)
        cap.stop()
        await asyncio.wait_for(task, 5)
        self.assertIsNotNone(cap._proc.returncode)


class WavSourceTest(unittest.IsolatedAsyncioTestCase):
    async def test_emits_silence_then_the_wav_when_played(self):
        hub = FrameHub()
        got = []
        hub.add(lambda f: got.append(f.pcm))
        src = WavSource(LOUD + LOUD[:100], hub, realtime=False)
        task = asyncio.ensure_future(src.run())
        while len(got) < 3:
            await asyncio.sleep(0)
        src.play()
        start = len(got)
        while len(got) < start + 4:
            await asyncio.sleep(0)
        src.stop()
        await asyncio.wait_for(task, 5)
        self.assertEqual(got[0], SILENCE)
        played = got[start:start + 3]
        self.assertEqual(played[0], LOUD)
        self.assertEqual(len(played[1]), FRAME_BYTES)  # the partial last frame is padded with zeros
        self.assertEqual(played[1][100:], bytes(FRAME_BYTES - 100))
        self.assertEqual(played[2], SILENCE)


if __name__ == "__main__":
    unittest.main()
