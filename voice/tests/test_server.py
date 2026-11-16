import asyncio
import json
import unittest

from near_voice.audio import FrameHub
from near_voice.segmenter import SegmenterConfig
from near_voice.server import VoiceServer

from .helpers import HISS, LOUD, SILENCE, EnergyVad, FakeChimes, FakeStt, first_sample, frame

# Default config: speech confirmed after 8 frames, ended by 19 silent frames, no speech after 125 frames.
END_SILENCE = 19


class Client:
    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer

    def send(self, obj) -> None:
        self.writer.write((json.dumps(obj) + "\n").encode())

    def send_raw(self, data: bytes) -> None:
        self.writer.write(data)

    async def next(self, skip_levels: bool = True, timeout: float = 5.0) -> dict:
        while True:
            line = await asyncio.wait_for(self.reader.readline(), timeout)
            if not line:
                raise ConnectionError("closed")
            ev = json.loads(line)
            if skip_levels and ev["ev"] == "level":
                continue
            return ev

    async def expect(self, ev_name: str, **fields) -> dict:
        ev = await self.next()
        self.assertion(ev, ev_name, fields)
        return ev

    @staticmethod
    def assertion(ev, ev_name, fields):
        if ev["ev"] != ev_name or any(ev.get(k) != v for k, v in fields.items()):
            raise AssertionError(f"expected {ev_name} {fields}, got {ev}")

    async def nothing_for(self, seconds: float = 0.2, skip_levels: bool = True) -> None:
        """No event other than (optionally) levels arrives within [seconds]."""
        loop = asyncio.get_running_loop()
        end = loop.time() + seconds
        while True:
            try:
                line = await asyncio.wait_for(self.reader.readline(), max(0.0, end - loop.time()))
            except asyncio.TimeoutError:
                return
            if skip_levels and json.loads(line)["ev"] == "level":
                continue
            raise AssertionError(f"unexpected event {line!r}")

    async def close(self):
        if not self.writer.is_closing():
            self.writer.close()
        try:
            await self.writer.wait_closed()
        except ConnectionError:
            pass


class ServerTestBase(unittest.IsolatedAsyncioTestCase):
    config = SegmenterConfig()
    grace = 1.0

    async def asyncSetUp(self):
        self.vad = EnergyVad()
        self.stt = FakeStt()
        self.chimes = FakeChimes()
        self.hub = FrameHub()
        self.clients = []
        self.server = VoiceServer(self.vad, self.stt, self.chimes, config=self.config, no_audio_grace_s=self.grace)
        self.hub.add(self.server.on_frame)
        self.port = await self.server.start("127.0.0.1", 0)
        self.client = await self.connect()

    async def asyncTearDown(self):
        for c in self.clients:
            await c.close()
        await self.server.close()

    async def connect(self) -> Client:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        c = Client(reader, writer)
        self.clients.append(c)
        await c.expect("ready")
        return c

    def push(self, pcm: bytes, count: int = 1) -> None:
        for _ in range(count):
            self.hub.push(pcm)

    def utterance(self, speech: int = 20) -> None:
        self.push(SILENCE, 5)
        self.push(LOUD, speech)
        self.push(SILENCE, END_SILENCE)

    async def listen(self, id_: str, client: Client = None) -> None:
        c = client or self.client
        c.send({"cmd": "listen", "id": id_})
        await c.expect("listening", id=id_)


class ListenTest(ServerTestBase):
    async def test_ready_announces_model_and_capabilities(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        ev = json.loads(await reader.readline())
        await Client(reader, writer).close()
        self.assertEqual(ev, {"ev": "ready", "model": "fake-model", "stt": "fake", "tts": False, "wake": "off"})

    async def test_utterance_gives_processing_then_final(self):
        await self.listen("a1")
        self.utterance()
        await self.client.expect("processing", id="a1")
        ev = await self.client.expect("final", id="a1", text="ĐẶT HẸN GIỜ MƯỜI LĂM PHÚT", engine="fake")
        self.assertEqual(ev["audio_ms"], (5 + 20 + 9) * 32)  # lead clipped at the 5 silent frames, 9 tail frames
        self.assertGreaterEqual(ev["stt_ms"], 0)
        self.assertEqual(len(self.stt.calls), 1)
        self.assertEqual(self.vad.resets, 1)

    async def test_levels_are_sent_about_ten_times_a_second_while_listening(self):
        self.push(LOUD, 6)  # not listening: no levels
        await self.listen("a1")
        self.push(SILENCE, 9)
        levels = []
        for _ in range(3):
            ev = await self.client.next(skip_levels=False)
            self.assertEqual(ev["ev"], "level")
            levels.append(ev["db"])
        self.assertEqual(levels, [-100.0, -100.0, -100.0])
        await self.client.nothing_for(0.1, skip_levels=False)

    async def test_preroll_keeps_words_said_just_before_the_touch(self):
        self.push(SILENCE, 40)
        self.push(frame(9000), 6)  # speech starts before "listen" arrives
        await self.listen("a1")
        self.push(LOUD, 10)
        self.push(SILENCE, END_SILENCE)
        await self.client.expect("processing", id="a1")
        await self.client.expect("final", id="a1")
        pcm = self.stt.calls[0]
        self.assertEqual(first_sample(pcm), 0)  # lead silence from the pre-roll
        self.assertIn(frame(9000), pcm)

    async def test_listen_from_an_explicit_frame_skips_earlier_audio(self):
        self.push(LOUD, 10)  # e.g. the wake word
        start = self.server.ring.latest + 1
        self.push(frame(12000), 10)
        self.server.begin_listen("w1", from_index=start)
        await self.client.expect("listening", id="w1")
        self.push(SILENCE, END_SILENCE)
        await self.client.expect("processing", id="w1")
        await self.client.expect("final", id="w1")
        self.assertEqual(first_sample(self.stt.calls[0]), 12000)

    async def test_silence_with_a_working_mic_is_no_speech(self):
        await self.listen("a1")
        self.push(HISS, 125)
        await self.client.expect("timeout", id="a1", reason="no_speech")
        self.assertEqual(self.stt.calls, [])

    async def test_digital_silence_is_no_audio(self):
        await self.listen("a1")
        self.push(SILENCE, 125)
        await self.client.expect("timeout", id="a1", reason="no_audio")

    async def test_stt_failure_is_an_error_event(self):
        self.stt.fail = RuntimeError("model gone")
        await self.listen("a1")
        with self.assertLogs("near_voice.server", "ERROR"):
            self.utterance()
            await self.client.expect("processing", id="a1")
            ev = await self.client.expect("error")
        self.assertIn("model gone", ev["msg"])

    async def test_frames_after_the_utterance_are_not_fed(self):
        await self.listen("a1")
        self.utterance()
        self.push(LOUD, 30)
        await self.client.expect("processing", id="a1")
        await self.client.expect("final", id="a1")
        await self.client.nothing_for(0.1)
        self.assertEqual(len(self.stt.calls), 1)


class CancelTest(ServerTestBase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.stt.release.clear()  # STT blocks until released

    async def finish_stt(self):
        self.stt.release.set()
        await asyncio.get_running_loop().run_in_executor(None, self.stt.finished.wait, 5)
        await asyncio.sleep(0.05)

    async def test_cancel_while_listening_stops_quietly(self):
        await self.listen("a1")
        self.push(LOUD, 10)
        self.client.send({"cmd": "cancel"})
        await self.client.nothing_for(0.1)
        self.push(SILENCE, END_SILENCE + 125)
        await self.client.nothing_for(0.1)
        self.assertEqual(self.stt.calls, [])

    async def test_final_of_a_cancelled_listen_is_dropped(self):
        await self.listen("a1")
        self.utterance()
        await self.client.expect("processing", id="a1")
        self.client.send({"cmd": "cancel"})
        await asyncio.sleep(0.05)
        await self.finish_stt()
        await self.client.nothing_for(0.2)

    async def test_a_new_listen_supersedes_the_pending_one(self):
        await self.listen("a1")
        self.utterance()
        await self.client.expect("processing", id="a1")
        await self.listen("a2")
        self.utterance()
        await self.client.expect("processing", id="a2")
        await self.finish_stt()
        await self.client.expect("final", id="a2")
        await self.client.nothing_for(0.2)

    async def test_last_client_leaving_cancels_the_listen(self):
        await self.listen("a1")
        await self.client.close()
        for _ in range(100):
            if self.server._listen is None:
                break
            await asyncio.sleep(0.01)
        self.assertIsNone(self.server._listen)


class NoAudioWatchdogTest(ServerTestBase):
    config = SegmenterConfig(no_speech_s=0.1)
    grace = 0.1

    async def test_mic_that_delivers_nothing_times_out_as_no_audio(self):
        await self.listen("a1")
        with self.assertLogs("near_voice.server", "ERROR"):
            await self.client.expect("timeout", id="a1", reason="no_audio")

    async def test_watchdog_does_not_fire_while_someone_is_speaking(self):
        await self.listen("a1")
        self.push(LOUD, 10)
        await asyncio.sleep(0.4)
        await self.client.nothing_for(0.1)
        self.push(SILENCE, END_SILENCE)
        await self.client.expect("processing", id="a1")


class CommandsTest(ServerTestBase):
    async def test_malformed_line_gets_an_error_and_the_connection_survives(self):
        with self.assertLogs("near_voice.server", "WARNING"):
            self.client.send_raw(b"not json\n")
            ev = await self.client.expect("error")
        self.assertIn("bad command", ev["msg"])
        await self.listen("a1")

    async def test_bad_command_error_goes_only_to_its_sender(self):
        app = await self.connect()
        await self.listen("a1", client=app)
        await self.client.expect("listening", id="a1")
        with self.assertLogs("near_voice.server", "WARNING"):
            self.client.send_raw(b"{oops\n")
            await self.client.expect("error")
        await app.nothing_for(0.2)
        self.assertIsNotNone(self.server._listen)

    async def test_unknown_command_is_ignored(self):
        self.client.send({"cmd": "say", "id": "s1", "text": "xin chào"})
        self.client.send_raw(b"\n")
        await self.listen("a1")

    async def test_chime_is_played(self):
        self.client.send({"cmd": "chime", "name": "alert"})
        for _ in range(100):
            if self.chimes.played:
                break
            await asyncio.sleep(0.01)
        self.assertEqual(self.chimes.played, ["alert"])

    async def test_before_listen_hooks_run_and_a_failing_one_does_not_block(self):
        seen = []

        def broken(_):
            raise RuntimeError("boom")

        self.server.before_listen.append(broken)
        self.server.before_listen.append(seen.append)
        with self.assertLogs("near_voice.server", "ERROR"):
            await self.listen("a1")
        self.assertEqual(seen, ["a1"])

    async def test_events_go_to_every_connected_client(self):
        other = await self.connect()
        await self.listen("a1")
        await other.expect("listening", id="a1")
        await other.close()


if __name__ == "__main__":
    unittest.main()
