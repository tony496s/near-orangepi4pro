import os
import tempfile
import threading
import unittest

from near_voice.audio import Frame
from near_voice.wake import (_RESET, DEFAULT_KEYWORDS, KEYWORDS_DIR, WakeHit, WakeWorker, pick_kws_files)

from .helpers import LOUD, SILENCE

ZHEN_FILES = [  # what sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20 holds
    "decoder-epoch-13-avg-2-chunk-16-left-64.onnx", "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
    "encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx", "encoder-epoch-13-avg-2-chunk-16-left-64.onnx",
    "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx", "encoder-epoch-13-avg-2-chunk-8-left-64.onnx",
    "joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx", "joiner-epoch-13-avg-2-chunk-16-left-64.onnx",
    "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx", "joiner-epoch-13-avg-2-chunk-8-left-64.onnx",
    "tokens.txt", "en.phone",
]


class PickKwsFilesTest(unittest.TestCase):
    def make(self, names):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        d = tmp.name
        for n in names:
            open(os.path.join(d, n), "w").close()
        return d

    def test_picks_the_e5_files_of_the_zh_en_model(self):
        files = pick_kws_files(self.make(ZHEN_FILES))
        self.assertEqual({k: os.path.basename(v) for k, v in files.items()}, {
            "encoder": "encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx",
            "decoder": "decoder-epoch-13-avg-2-chunk-16-left-64.onnx",
            "joiner": "joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx",
            "tokens": "tokens.txt",
        })

    def test_never_the_int8_decoder(self):
        d = self.make(["decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx", "decoder-epoch-12-avg-2-chunk-16-left-64.onnx",
                       "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                       "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx", "tokens.txt"])
        self.assertEqual(os.path.basename(pick_kws_files(d)["decoder"]), "decoder-epoch-12-avg-2-chunk-16-left-64.onnx")

    def test_missing_file_is_a_clear_error(self):
        with self.assertRaises(FileNotFoundError) as ctx:
            pick_kws_files(self.make(["tokens.txt", "encoder-x.int8.onnx", "joiner-x.int8.onnx"]))
        self.assertIn("decoder", str(ctx.exception))


class KeywordFilesTest(unittest.TestCase):
    def test_keyword_files_use_e5_tokens_and_one_label(self):
        self.assertTrue(DEFAULT_KEYWORDS.startswith(KEYWORDS_DIR))
        for name in sorted(os.listdir(KEYWORDS_DIR)):
            with self.subTest(name=name):
                with open(os.path.join(KEYWORDS_DIR, name)) as f:
                    lines = [line.split() for line in f.read().splitlines() if line.strip()]
                self.assertTrue(lines)
                for words in lines:
                    self.assertEqual(words[-1], "@HEY_NEAR")
                    self.assertTrue(set(words[:-1]) <= {"HH", "EY1", "AY1", "N", "IH1", "IY1", "R", "AH0"})
        with open(DEFAULT_KEYWORDS) as f:
            self.assertEqual(f.read(), "HH EY1 N IH1 R @HEY_NEAR\n")  # the E5 set that caught the most


class FakeSpotter:
    name = "fake-kws"

    def __init__(self, hit_on=LOUD, fail_on=None):
        self.hit_on, self.fail_on = hit_on, fail_on
        self.fed = []
        self.resets = 0

    def accept(self, pcm):
        self.fed.append(pcm)
        if self.fail_on is not None and pcm == self.fail_on:
            raise RuntimeError("decode failed")
        return "HEY_NEAR " if pcm == self.hit_on else None

    def reset(self):
        self.resets += 1


class WakeWorkerTest(unittest.TestCase):
    def setUp(self):
        self.spotter = FakeSpotter()
        self.hits = []
        self.wanted = True
        self.worker = WakeWorker(self.spotter, lambda: self.wanted, self.hits.append, lambda fn, *a: fn(*a),
                                 cooldown_s=0.32, queue_s=0.32)  # cooldown and queue: 10 frames
        self.index = 0

    def frame(self, pcm):
        f = Frame(self.index, pcm)
        self.index += 1
        return f

    def drain(self):
        while not self.worker._queue.empty():
            self.worker.handle(self.worker._queue.get_nowait())

    def feed(self, pcm, count=1):
        for _ in range(count):
            self.worker.on_frame(self.frame(pcm))
            self.drain()

    def test_a_hit_is_posted_with_the_frame_it_was_heard_at(self):
        self.feed(SILENCE, 5)
        self.feed(LOUD)
        self.assertEqual(self.hits, [WakeHit("HEY_NEAR", 5)])

    def test_one_wake_word_fires_once(self):
        self.feed(LOUD)
        self.feed(LOUD, 10)  # frames 1-10, the cooldown: not even fed
        self.assertEqual(len(self.hits), 1)
        self.assertEqual(len(self.spotter.fed), 1)
        self.feed(LOUD)  # frame 11
        self.assertEqual([h.index for h in self.hits], [0, 11])

    def test_nothing_is_fed_while_not_wanted(self):
        self.wanted = False
        self.feed(LOUD, 5)
        self.assertEqual((self.spotter.fed, self.hits), ([], []))

    def test_feeding_starts_fresh_after_a_gap(self):
        self.feed(SILENCE, 3)
        resets = self.spotter.resets
        self.wanted = False
        self.feed(SILENCE, 3)  # e.g. a listen was open
        self.wanted = True
        self.feed(SILENCE)
        self.assertEqual(self.spotter.resets, resets + 1)

    def test_a_failing_decode_is_logged_and_spotting_goes_on(self):
        self.spotter.fail_on = SILENCE
        with self.assertLogs("near_voice.wake", "ERROR"):
            self.feed(SILENCE)
        self.feed(LOUD)
        self.assertEqual(len(self.hits), 1)

    def test_a_spotter_far_behind_drops_frames_instead_of_falling_further_behind(self):
        with self.assertLogs("near_voice.wake", "WARNING"):
            for _ in range(15):
                self.worker.on_frame(self.frame(SILENCE))  # nothing drained: the spotter thread is stuck
        self.assertEqual(self.worker._queue.qsize(), 10)
        self.assertEqual(self.worker.dropped, 6)  # the reset marker took one slot

    def test_runs_in_its_own_thread_and_stops(self):
        posted = threading.Event()
        worker = WakeWorker(FakeSpotter(), lambda: True, lambda hit: posted.set(), lambda fn, *a: fn(*a))
        worker.start()
        worker.on_frame(Frame(0, SILENCE))
        worker.on_frame(Frame(1, LOUD))
        self.assertTrue(posted.wait(2.0))
        worker.stop()
        self.assertIsNone(worker._thread)

    def test_stop_works_with_a_full_queue(self):
        for i in range(15):
            self.worker.on_frame(Frame(i, SILENCE))
        self.worker.start()
        self.worker.stop(timeout=2.0)
        self.assertIsNone(self.worker._thread)

    def test_the_reset_marker_resets_the_spotter(self):
        self.worker.handle(_RESET)
        self.assertEqual(self.spotter.resets, 1)


if __name__ == "__main__":
    unittest.main()
