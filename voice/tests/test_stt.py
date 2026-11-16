import os
import tempfile
import threading
import time
import unittest

from near_voice.stt import CloudFirstStt, pick_model_files

from .helpers import FakeStt


class PickModelFilesTest(unittest.TestCase):
    def make(self, d, names):
        for n in names:
            open(os.path.join(d, n), "w").close()

    def test_prefers_int8_files_like_the_e4_model(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d, ["encoder.int8.onnx", "encoder.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt",
                          "bpe.model"])
            files = pick_model_files(d)
        self.assertEqual({k: os.path.basename(v) for k, v in files.items()},
                         {"encoder": "encoder.int8.onnx", "decoder": "decoder.onnx", "joiner": "joiner.int8.onnx",
                          "tokens": "tokens.txt"})

    def test_missing_file_is_a_clear_error(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d, ["encoder.int8.onnx", "decoder.onnx", "tokens.txt"])
            with self.assertRaises(FileNotFoundError) as ctx:
                pick_model_files(d)
        self.assertIn("joiner", str(ctx.exception))



class SlowCloud:
    name = "deepgram"
    model = "harness-stt-vi"

    def __init__(self, text="Đặt hẹn giờ 15 phút.", delay=0.0, fail=None):
        self.text, self.delay, self.fail = text, delay, fail
        self.started = threading.Event()
        self.calls = []

    def transcribe(self, pcm):
        self.calls.append(pcm)
        self.started.set()
        time.sleep(self.delay)
        if self.fail is not None:
            raise self.fail
        return self.text


class CloudFirstSttTest(unittest.TestCase):
    def test_the_cloud_words_win_when_they_come_in_time(self):
        local = FakeStt("ĐẶT HẸN GIỜ MƯỜI LĂM PHÚT")
        stt = CloudFirstStt(SlowCloud(" Đặt hẹn giờ 15 phút. "), local, timeout_s=2.0)
        self.assertEqual(stt.transcribe(b"pcm"), "Đặt hẹn giờ 15 phút.")
        self.assertEqual(stt.last_engine, "deepgram")
        self.assertEqual((stt.name, stt.model), ("deepgram", "harness-stt-vi+fake-model"))
        self.assertEqual(local.calls, [b"pcm"])  # the local decode always runs: it is the fallback

    def test_both_run_at_the_same_time(self):
        cloud = SlowCloud(delay=0.3)
        local = FakeStt(block=True)
        stt = CloudFirstStt(cloud, local, timeout_s=2.0)
        done = threading.Thread(target=stt.transcribe, args=(b"pcm",))
        done.start()
        self.assertTrue(cloud.started.wait(1.0), "the cloud call waited for the local decode")
        local.release.set()
        done.join(2.0)

    def test_a_cloud_failure_falls_back_to_the_local_words(self):
        stt = CloudFirstStt(SlowCloud(fail=RuntimeError("HTTP 429 VOICE_QUOTA_EXCEEDED")), FakeStt("TIẾP THEO LÀ GÌ"))
        with self.assertLogs("near_voice.stt", "WARNING"):
            self.assertEqual(stt.transcribe(b"pcm"), "TIẾP THEO LÀ GÌ")
        self.assertEqual(stt.last_engine, "fake")

    def test_a_slow_cloud_falls_back_after_the_timeout(self):
        stt = CloudFirstStt(SlowCloud(delay=1.0), FakeStt("TIẾP THEO LÀ GÌ"), timeout_s=0.2)
        t0 = time.perf_counter()
        self.assertEqual(stt.transcribe(b"pcm"), "TIẾP THEO LÀ GÌ")
        self.assertLess(time.perf_counter() - t0, 0.6)
        self.assertEqual(stt.last_engine, "fake")

    def test_an_empty_cloud_answer_uses_the_local_words(self):
        stt = CloudFirstStt(SlowCloud("  "), FakeStt("TIẾP THEO LÀ GÌ"))
        self.assertEqual(stt.transcribe(b"pcm"), "TIẾP THEO LÀ GÌ")
        self.assertEqual(stt.last_engine, "fake")

    def test_the_answering_engine_is_set_per_sentence(self):
        cloud = SlowCloud()
        stt = CloudFirstStt(cloud, FakeStt("LOCAL"))
        stt.transcribe(b"1")
        cloud.fail = RuntimeError("offline")
        with self.assertLogs("near_voice.stt", "WARNING"):
            stt.transcribe(b"2")
        self.assertEqual(stt.last_engine, "fake")

    def test_both_transcripts_are_logged_locally(self):
        stt = CloudFirstStt(SlowCloud("cloud words"), FakeStt("LOCAL WORDS"))
        with self.assertLogs("near_voice.stt", "INFO") as logs:
            stt.transcribe(b"pcm")
        self.assertTrue(any("cloud words" in m and "LOCAL WORDS" in m for m in logs.output))


if __name__ == "__main__":
    unittest.main()
