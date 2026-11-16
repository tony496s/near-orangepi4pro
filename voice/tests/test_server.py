import asyncio
import json
import unittest

from near_voice.audio import FrameHub
from near_voice.segmenter import SegmenterConfig
from near_voice.server import VoiceServer
from near_voice.wake import WakeHit

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
    wake_listen = 1.5

    async def asyncSetUp(self):
        self.vad = EnergyVad()
        self.stt = FakeStt()
        self.chimes = FakeChimes()
        self.hub = FrameHub()
        self.clients = []
        self.server = VoiceServer(self.vad, self.stt, self.chimes, config=self.config, no_audio_grace_s=self.grace,
                                  wake_listen_s=self.wake_listen)
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
        self.assertEqual(ev, {"ev": "ready", "model": "fake-model", "stt": "fake", "tts": False, "wake": "off",
                              "langs": ["vi"]})

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

    async def test_quiet_room_through_a_noise_gate_is_no_speech(self):
        # The board mic idles at peak 24-47 in a quiet office: that is a working mic, not "no audio".
        await self.listen("a1")
        self.push(frame(47), 125)
        await self.client.expect("timeout", id="a1", reason="no_speech")

    async def test_finish_transcribes_what_was_said_so_far(self):
        await self.listen("a1")
        self.push(SILENCE, 5)
        self.push(LOUD, 20)
        self.push(SILENCE, 3)  # tapped before the pause that would end it
        with self.assertLogs("near_voice.server", "INFO") as logs:
            self.client.send({"cmd": "finish"})
            await self.client.expect("processing", id="a1")
            await self.client.expect("final", id="a1")
        self.assertTrue(any("finished by the user" in m for m in logs.output))
        self.assertEqual(len(self.stt.calls[0]), (5 + 20 + 3) * 1024)
        self.push(LOUD, 30)  # nothing more is fed
        await self.client.nothing_for(0.1)

    async def test_finish_without_speech_times_out_at_once(self):
        await self.listen("a1")
        self.push(HISS, 10)
        self.client.send({"cmd": "finish"})
        await self.client.expect("timeout", id="a1", reason="no_speech")
        self.assertEqual(self.stt.calls, [])

    async def test_finish_when_not_listening_is_ignored(self):
        self.client.send({"cmd": "finish"})
        await self.listen("a1")

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



class EngineNameTest(ServerTestBase):
    async def test_final_names_the_engine_that_answered(self):
        self.stt.last_engine = "zipformer"  # e.g. CloudFirstStt fell back to the local model
        await self.listen("a1")
        self.utterance()
        await self.client.expect("processing", id="a1")
        await self.client.expect("final", id="a1", engine="zipformer")


class LanguageTest(ServerTestBase):
    """A listen names its language; English goes to its own engine (Harness in production)."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.en = FakeStt(text="Set a timer for 10 minutes.")
        self.en.name, self.en.model = "deepgram", "harness-stt-en"
        self.en.available = lambda: self.en_signed_in
        self.en_signed_in = True
        self.server.engines["en"] = self.en

    async def ready(self) -> dict:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        ev = json.loads(await reader.readline())
        await Client(reader, writer).close()
        return ev

    async def test_ready_lists_the_default_language_first(self):
        self.assertEqual((await self.ready())["langs"], ["vi", "en"])

    async def test_english_is_left_out_until_there_is_a_sign_in(self):
        self.en_signed_in = False
        self.assertEqual((await self.ready())["langs"], ["vi"])

    async def test_an_english_listen_goes_to_the_english_engine_only(self):
        self.client.send({"cmd": "listen", "id": "e1", "lang": "en"})
        await self.client.expect("listening", id="e1")
        self.utterance()
        await self.client.expect("processing", id="e1")
        await self.client.expect("final", id="e1", text="Set a timer for 10 minutes.", engine="deepgram")
        self.assertEqual((len(self.en.calls), len(self.stt.calls)), (1, 0))

    async def test_vi_or_no_lang_uses_the_default_engine(self):
        for id_, cmd in [("v1", {"lang": "vi"}), ("v2", {})]:
            with self.subTest(cmd=cmd):
                self.client.send({"cmd": "listen", "id": id_, **cmd})
                await self.client.expect("listening", id=id_)
                self.utterance()
                await self.client.expect("processing", id=id_)
                await self.client.expect("final", id=id_, engine="fake")
        self.assertEqual((len(self.en.calls), len(self.stt.calls)), (0, 2))

    async def test_a_language_the_service_lacks_is_an_error_and_no_listen(self):
        self.client.send({"cmd": "listen", "id": "f1", "lang": "fr"})
        await self.client.expect("error", msg="stt: no fr engine")
        self.assertIsNone(self.server._listen)
        await self.listen("v1")  # the next listen works

    async def test_a_failing_english_engine_is_an_error_not_vietnamese_words(self):
        self.en.fail = RuntimeError("HTTP 429 RATE_LIMITED")
        self.client.send({"cmd": "listen", "id": "e1", "lang": "en"})
        await self.client.expect("listening", id="e1")
        self.utterance()
        await self.client.expect("processing", id="e1")
        await self.client.expect("error")
        self.assertEqual(self.stt.calls, [], "the Vietnamese model must not answer an English listen")


class WakeTest(ServerTestBase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.server.wake_engine = "fake-kws"

    def hit(self) -> None:
        self.server.on_wake(WakeHit("HEY_NEAR", self.server.ring.latest))

    async def test_ready_names_the_spotter(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        ev = json.loads(await reader.readline())
        await Client(reader, writer).close()
        self.assertEqual(ev["wake"], "fake-kws")

    async def test_no_spotter_means_wake_is_never_wanted(self):
        self.server.wake_engine = None
        self.assertFalse(self.server.wake_wanted())

    async def test_wake_is_announced_and_the_listen_starts_after_the_wake_word(self):
        self.push(SILENCE, 10)
        self.push(frame(9000), 12)  # "Hey Near"
        self.assertTrue(self.server.wake_wanted())
        self.hit()
        await self.client.expect("wake", keyword="HEY_NEAR")
        self.push(frame(12000), 8)  # the command starts before the app's "listen" arrives
        await self.listen("w1")
        self.push(LOUD, 10)
        self.push(SILENCE, END_SILENCE)
        await self.client.expect("processing", id="w1")
        await self.client.expect("final", id="w1")
        pcm = self.stt.calls[0]
        self.assertEqual(first_sample(pcm), 12000)
        self.assertFalse(frame(9000) in pcm, "the wake word was transcribed")

    async def test_a_wake_is_used_by_one_listen_only(self):
        starts = []
        begin = self.server.begin_listen
        self.server.begin_listen = lambda id_, from_index=None, stt=None: (starts.append((id_, from_index)),
                                                                           begin(id_, from_index, stt))
        self.push(frame(9000), 12)
        self.hit()
        wake_at = self.server.ring.latest
        await self.client.expect("wake")
        await self.listen("w1")
        self.client.send({"cmd": "cancel"})
        await self.listen("a2")
        self.assertEqual(starts, [("w1", wake_at + 1), ("a2", None)])

    async def test_wake_while_listening_is_not_wanted_and_not_sent(self):
        await self.listen("a1")
        self.assertFalse(self.server.wake_wanted())
        self.hit()
        await self.client.nothing_for(0.1)

    async def test_wake_while_waiting_for_words_is_not_wanted(self):
        self.stt.release.clear()  # STT blocks: the listen is waiting for its words
        await self.listen("a1")
        self.utterance()
        await self.client.expect("processing", id="a1")
        self.assertFalse(self.server.wake_wanted())
        self.stt.release.set()
        await self.client.expect("final", id="a1")
        self.assertTrue(self.server.wake_wanted())

    async def test_the_app_turns_wake_off_and_on(self):
        self.client.send({"cmd": "wake", "on": False})
        await self.listen("a1")  # a round trip, so the wake command has been handled
        self.client.send({"cmd": "cancel"})
        await self.listen("a2")
        self.client.send({"cmd": "cancel"})
        await self.client.nothing_for(0.05)
        self.assertFalse(self.server.wake_on)
        self.assertFalse(self.server.wake_wanted())
        self.hit()
        await self.client.nothing_for(0.1)
        self.client.send({"cmd": "wake", "on": True})
        await self.listen("a3")
        self.client.send({"cmd": "cancel"})
        await self.client.nothing_for(0.05)
        self.assertTrue(self.server.wake_wanted())

    async def test_no_app_connected_means_no_wake(self):
        await self.client.close()
        for _ in range(50):
            if not self.server.wake_wanted():
                break
            await asyncio.sleep(0.01)
        self.assertFalse(self.server.wake_wanted())


class ShortWakeWindowTest(ServerTestBase):
    wake_listen = 0.1

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.server.wake_engine = "fake-kws"

    async def test_a_listen_after_the_wake_window_uses_the_normal_preroll(self):
        self.push(frame(9000), 12)
        self.server.on_wake(WakeHit("HEY_NEAR", self.server.ring.latest))
        await self.client.expect("wake")
        await asyncio.sleep(0.15)  # wake_listen is 0.1 s in this class
        self.push(frame(12000), 4)
        await self.listen("a1")
        self.push(LOUD, 10)
        self.push(SILENCE, END_SILENCE)
        await self.client.expect("processing", id="a1")
        await self.client.expect("final", id="a1")
        self.assertTrue(frame(9000) in self.stt.calls[0], "no pre-roll")  # 0.5 s back, across the wake word


if __name__ == "__main__":
    unittest.main()
