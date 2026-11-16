import argparse
import io
import json
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

import numpy as np

from near_wake import evaluate as ev
from near_wake import synth

SR = 16000


class LevelScorer:
    """Score = the frame's loudest sample / 10000, so a test writes the scores it wants into the audio itself.

    Scores then follow the audio, whatever the padding or frame alignment.
    """

    def __init__(self, keep_frames=False):
        self.keep_frames = keep_frames
        self.resets = 0
        self.frames = []
        self.calls = 0

    def reset(self):
        self.resets += 1

    def score(self, frame):
        self.calls += 1
        if self.keep_frames:
            self.frames.append(np.array(frame))
        return float(np.abs(frame.astype(np.int32)).max()) / 10000.0


class ScriptedScorer:
    """Returns scripted scores, one per frame since the last reset, then 0."""

    def __init__(self, scores):
        self.scores = list(scores)
        self.k = 0

    def reset(self):
        self.k = 0

    def score(self, frame):
        self.k += 1
        return self.scores[self.k - 1] if self.k <= len(self.scores) else 0.0


def audio(total_s, bursts=(), dur_s=0.2):
    """int16 silence of [total_s] with constant-level bursts: (start_s, level) each lasting [dur_s]."""
    x = np.zeros(int(round(total_s * SR)), dtype=np.int16)
    for start, level in bursts:
        a = int(round(start * SR))
        x[a:a + int(round(dur_s * SR))] = level
    return x


def tmpdir(test):
    d = tempfile.TemporaryDirectory()
    test.addCleanup(d.cleanup)
    return Path(d.name)


class ScoreClipTest(unittest.TestCase):
    def test_pads_one_second_before_and_half_a_second_after(self):
        clip = np.full(8000, 7, dtype=np.int16)  # 0.5 s
        scorer = LevelScorer(keep_frames=True)
        ev.score_clip(scorer, clip)
        self.assertEqual(scorer.resets, 1)
        self.assertEqual(len(scorer.frames), 25, "1.0 + 0.5 + 0.5 s = 32000 samples = 25 frames")
        self.assertTrue(all(f.dtype == np.int16 and len(f) == ev.FRAME for f in scorer.frames))
        fed = np.concatenate(scorer.frames)
        np.testing.assert_array_equal(fed, np.concatenate([np.zeros(16000), clip, np.zeros(8000)]).astype(np.int16))

    def test_tail_is_filled_to_a_whole_frame(self):
        scorer = LevelScorer(keep_frames=True)
        ev.score_clip(scorer, np.full(8001, 7, dtype=np.int16))
        self.assertEqual(len(scorer.frames), 26)
        self.assertEqual(int(np.concatenate(scorer.frames)[16000 + 8001:].max()), 0)

    def test_returns_the_highest_frame_score(self):
        self.assertEqual(ev.score_clip(ScriptedScorer([0.1, 0.9, 0.3]), audio(0.5)), 0.9)
        self.assertAlmostEqual(ev.score_clip(LevelScorer(), audio(0.8, [(0.3, 6000)])), 0.6)

    def test_the_very_end_of_the_clip_is_scored(self):
        clip = np.zeros(SR, dtype=np.int16)
        clip[-1] = 9000
        self.assertAlmostEqual(ev.score_clip(LevelScorer(), clip), 0.9)

    def test_reset_before_each_clip(self):
        scorer = ScriptedScorer([0.0] * 14 + [0.8])
        self.assertEqual(ev.score_clip(scorer, audio(0.5)), 0.8)
        self.assertEqual(ev.score_clip(scorer, audio(0.5)), 0.8, "the script starts over: the scorer was reset")

    def test_float_and_empty_input(self):
        self.assertAlmostEqual(ev.score_clip(LevelScorer(), np.full(1000, 0.5, dtype=np.float32)), 16384 / 10000)
        self.assertEqual(ev.score_clip(LevelScorer(), np.zeros(0, dtype=np.int16)), 0.0)


class FrameScoresTest(unittest.TestCase):
    def test_times_are_frame_ends_from_the_recording_start(self):
        times, scores = ev.frame_scores(LevelScorer(), audio(1.0, [(0.5, 5000)], dur_s=0.01))
        self.assertAlmostEqual(times[0], 0.08 - 1.0)
        self.assertEqual(len(times), len(scores))
        first = times[np.argmax(scores > 0)]
        self.assertTrue(0.5 <= first < 0.5 + 0.08, first)


class DetectionsTest(unittest.TestCase):
    TIMES = np.arange(1, 60) * ev.FRAME / SR

    def scores(self, hot):
        s = np.zeros(len(self.TIMES))
        for k, v in hot.items():
            s[k - 1] = v  # frame k ends at 0.08 * k
        return s

    def test_cooldown_after_each_detection_as_on_the_device(self):
        # 1.04 fires; 1.12 and 2.96 are within 2 s of it; 3.04 is 2.0 s after it, so it fires again, even though
        # it is only 0.08 s after 2.96 (merging each detection into the previous one would have dropped it).
        s = self.scores({13: 0.9, 14: 0.9, 37: 0.9, 38: 0.9})
        self.assertEqual(ev.detections(self.TIMES, s, 0.5, cooldown_s=2.0), [1.04, 3.04])

    def test_threshold_is_inclusive(self):
        s = self.scores({10: 0.5, 40: 0.49})
        self.assertEqual(ev.detections(self.TIMES, s, 0.5), [0.8])

    def test_no_cooldown_reports_every_frame(self):
        s = self.scores({10: 0.9, 11: 0.9, 12: 0.9})
        self.assertEqual(ev.detections(self.TIMES, s, 0.5, cooldown_s=0.0), [0.8, 0.88, 0.96])

    def test_detection_inside_the_leading_pad_is_clamped_to_zero(self):
        self.assertEqual(ev.detections([-0.5, 0.2], [0.9, 0.0], 0.5), [0.0])


class ScanStreamTest(unittest.TestCase):
    def test_bursts_within_the_cooldown_merge(self):
        x = audio(12.0, [(2.0, 8000), (3.5, 8000), (6.0, 8000), (6.5, 9000)], dur_s=0.3)
        scorer = LevelScorer()
        times = ev.scan_stream(scorer, x, 0.5, cooldown_s=2.0)
        self.assertEqual(len(times), 2, times)
        self.assertTrue(2.0 <= times[0] < 2.08, times)
        self.assertTrue(6.0 <= times[1] < 6.08, times)
        self.assertEqual(scorer.resets, 1)

    def test_longer_cooldown_merges_more_and_threshold_filters(self):
        x = audio(12.0, [(2.0, 8000), (6.0, 8000)])
        self.assertEqual(len(ev.scan_stream(LevelScorer(), x, 0.5, cooldown_s=5.0)), 1)
        self.assertEqual(ev.scan_stream(LevelScorer(), x, 0.9), [])

    def test_quiet_recording_has_no_detections(self):
        self.assertEqual(ev.scan_stream(LevelScorer(), audio(5.0), 0.3), [])


class EvaluateTest(unittest.TestCase):
    THRESHOLDS = [0.3, 0.5, 0.7, 0.9]

    def run_eval(self, positives, negatives, thresholds=None):
        made = []

        def factory():
            made.append(LevelScorer())
            return made[-1]

        result = ev.evaluate(factory, iter(positives), iter(negatives), thresholds or self.THRESHOLDS)
        self.assertEqual(len(made), 1, "one scorer for the whole run")
        return result

    def positives(self):
        return [(f"p{i}", audio(0.8, [(0.3, level)])) for i, level in enumerate([9000, 6000, 4000, 2000], 1)]

    def negatives(self):
        long = audio(360.0, [(10.0, 6000), (100.0, 9500), (200.0, 3500)])
        short = audio(1.0, [(0.3, 8000)])
        return [("long.wav", long), ("short.wav", short)]

    def test_recall_false_alarms_and_the_threshold_sweep(self):
        r = self.run_eval(self.positives(), self.negatives())
        hours = 361.0 / 3600
        self.assertAlmostEqual(r["negative_hours"], hours)
        self.assertEqual((r["positives"], r["negative_files"]), (4, 2))
        self.assertEqual({k: round(v, 3) for k, v in r["positive_scores"].items()},
                         {"p1": 0.9, "p2": 0.6, "p3": 0.4, "p4": 0.2})
        by_th = {row["threshold"]: row for row in r["thresholds"]}
        self.assertEqual(list(by_th), self.THRESHOLDS)
        expected = {0.3: (3, ["p4"], 4), 0.5: (2, ["p3", "p4"], 3), 0.7: (1, ["p2", "p3", "p4"], 2),
                    0.9: (1, ["p2", "p3", "p4"], 1)}
        for th, (hits, missed, fa) in expected.items():
            with self.subTest(threshold=th):
                row = by_th[th]
                self.assertEqual((row["hits"], row["positives"], row["missed"]), (hits, 4, missed))
                self.assertAlmostEqual(row["recall"], hits / 4)
                self.assertEqual(row["false_alarms"], fa)
                self.assertAlmostEqual(row["fa_per_hour"], fa / hours)

    def test_false_alarm_times_per_negative_file(self):
        r = self.run_eval(self.positives(), self.negatives())
        by_th = {row["threshold"]: row for row in r["thresholds"]}
        low = by_th[0.3]["false_alarm_times"]
        self.assertEqual(sorted(low), ["long.wav", "short.wav"])
        self.assertEqual(len(low["long.wav"]), 3)
        for got, want in zip(low["long.wav"], [10.0, 100.0, 200.0], strict=True):
            self.assertTrue(want <= got < want + 0.08, (got, want))
        self.assertEqual(len(low["short.wav"]), 1)
        self.assertEqual(list(by_th[0.9]["false_alarm_times"]), ["long.wav"],
                         "files without a false alarm are left out")

    def test_without_negatives_or_positives(self):
        r = self.run_eval(self.positives(), [])
        self.assertEqual(r["negative_hours"], 0.0)
        self.assertTrue(all(row["fa_per_hour"] is None and row["false_alarms"] == 0 for row in r["thresholds"]))
        r = self.run_eval([], self.negatives()[1:])
        self.assertTrue(all(row["recall"] is None and row["missed"] == [] for row in r["thresholds"]))

    def test_json_serializable(self):
        json.dumps(self.run_eval(self.positives()[:1], self.negatives()[1:]))


E4_SEGMENTS = [{"seg": 0, "start_s": 1.0, "end_s": 2.0, "dur_s": 1.0},
               {"seg": 1, "start_s": 4.0, "end_s": 5.5, "dur_s": 1.5},
               {"seg": 2, "start_s": 8.0, "end_s": 9.0, "dur_s": 1.0},
               {"seg": 3, "start_s": 11.0, "end_s": 12.0, "dur_s": 1.0},
               {"seg": 4, "start_s": 14.0, "end_s": 15.0, "dur_s": 1.0}]
E4_SUMMARY = {"alignment_from": "test", "unmatched_prompts": [],
              "mapping": [{"id": "01", "segs": [0]}, {"id": "15", "segs": [1]},
                          {"id": "W01", "segs": [2]}, {"id": "W02", "segs": [4]}]}


def make_e4(root, wav_rate=48000):
    """A small E4-like session dir: two commands, then wake prompts W01 and W02 with an unmatched take between them.

    Same layout as phase0/data/e4: results/summary.json, segments/segments.json, session1.wav (48 kHz, as recorded).
    """
    d = root / "e4"
    (d / "results").mkdir(parents=True)
    (d / "segments").mkdir()
    (d / "results" / "summary.json").write_text(json.dumps(E4_SUMMARY))
    (d / "segments" / "segments.json").write_text(json.dumps(E4_SEGMENTS))
    # A command at 4.5 s that should not wake, then three takes; the last one is quiet (scores 0.35).
    session = audio(18.0, [(4.5, 8000), (8.5, 8000), (11.5, 8000), (14.5, 3500)], dur_s=0.3)
    x = synth.resample(session.astype(np.float32) / 32767.0, SR, wav_rate)
    synth.write_wav(d / "session1.wav", x, wav_rate)
    return d


class E4Test(unittest.TestCase):
    SEGMENTS, SUMMARY = E4_SEGMENTS, E4_SUMMARY

    def test_spans_start_at_the_first_wake_segment(self):
        self.assertEqual(ev.wake_spans(self.SUMMARY, self.SEGMENTS), [(8.0, 9.0), (11.0, 12.0), (14.0, 15.0)],
                         "segment 3 is unmatched by STT but still a wake take")

    def test_no_wake_prompt_matched(self):
        self.assertEqual(ev.wake_spans({"mapping": [{"id": "01", "segs": [0]}]}, self.SEGMENTS), [])

    def test_load_e4_reads_summary_segments_and_wav(self):
        d = make_e4(tmpdir(self))
        e4 = ev.load_e4(d)
        self.assertEqual(e4["spans"], [(8.0, 9.0), (11.0, 12.0), (14.0, 15.0)])
        self.assertEqual(e4["wav"], d / "session1.wav")
        self.assertEqual(len(synth.read_wav_16k(e4["wav"])), 18 * SR)

    def test_load_e4_errors(self):
        d = make_e4(tmpdir(self))
        (d / "segments" / "segments.json").unlink()
        with self.assertRaises(FileNotFoundError) as ctx:
            ev.load_e4(d)
        self.assertIn("segments", str(ctx.exception))
        d = make_e4(tmpdir(self))
        (d / "results" / "summary.json").write_text(json.dumps({"mapping": [{"id": "01", "segs": [0]}]}))
        with self.assertRaises(ValueError):
            ev.load_e4(d)

    def test_session_hits_and_false_alarms(self):
        e4 = ev.load_e4(make_e4(tmpdir(self)))
        session = ev.as_int16(synth.read_wav_16k(e4["wav"]))
        r = ev.evaluate_session(LevelScorer(), session, e4["spans"], [0.3, 0.5, 0.9])
        self.assertAlmostEqual(r["seconds"], 18.0)
        self.assertAlmostEqual(r["non_wake_seconds"], 18.0 - 3 * 2.8)
        by_th = {row["threshold"]: row for row in r["thresholds"]}
        low = by_th[0.3]
        self.assertEqual((low["hits"], low["positives"], low["missed"]), (3, 3, []))
        self.assertEqual(len(low["false_alarms"]), 1)
        self.assertTrue(4.5 <= low["false_alarms"][0] < 4.58)
        self.assertAlmostEqual(low["fa_per_hour"], 1 / (9.6 / 3600))
        self.assertEqual((by_th[0.5]["hits"], by_th[0.5]["missed"]), (2, [2]))
        self.assertEqual((by_th[0.9]["hits"], by_th[0.9]["false_alarms"], by_th[0.9]["fa_per_hour"]), (0, [], 0.0))


class ScoreEventsTest(unittest.TestCase):
    SPANS = [(100.0, 101.0), (103.0, 104.0), (106.0, 107.0)]

    def test_hits_misses_and_false_alarms(self):
        s = ev.score_events([100.5, 104.9, 50.0], self.SPANS)
        self.assertEqual(s["hits"], 2)
        self.assertEqual(s["missed"], [2])
        self.assertEqual(s["false_alarms"], [50.0])

    def test_late_detection_within_tolerance_counts(self):
        self.assertEqual(ev.score_events([102.4], self.SPANS)["hits"], 1)
        self.assertEqual(ev.score_events([102.6], self.SPANS)["hits"], 0, "past 101 + 1.5 but before 103 - 0.3")

    def test_second_event_on_the_same_span_is_not_a_false_alarm(self):
        s = ev.score_events([100.2, 100.9], [(100.0, 101.0)])
        self.assertEqual((s["hits"], s["false_alarms"]), (1, []))


class NonWakeSecondsTest(unittest.TestCase):
    def test_overlapping_windows_count_once(self):
        # Windows (9.7, 12.5) and (11.7, 14.5) overlap: 9.7..14.5 is 4.8 s.
        self.assertAlmostEqual(ev.non_wake_seconds(100.0, [(10.0, 11.0), (12.0, 13.0)]), 95.2)

    def test_windows_are_clipped_to_the_recording(self):
        self.assertAlmostEqual(ev.non_wake_seconds(10.0, [(0.1, 1.0), (9.0, 9.5)]), 10.0 - 2.5 - 1.3)
        self.assertEqual(ev.non_wake_seconds(10.0, []), 10.0)


class PathsAndArgsTest(unittest.TestCase):
    def test_expand_dirs_globs_and_files(self):
        root = tmpdir(self)
        (root / "pos" / "sub").mkdir(parents=True)
        for rel in ["pos/a.wav", "pos/sub/b.wav", "pos/notes.txt", "c.wav"]:
            (root / rel).write_bytes(b"")
        self.assertEqual([p.name for p in ev.expand_paths([str(root / "pos")])], ["a.wav", "b.wav"])
        self.assertEqual([p.name for p in ev.expand_paths([str(root / "*.wav")])], ["c.wav"])
        self.assertEqual([p.name for p in ev.expand_paths([str(root / "c.wav"), str(root / "c.wav")])], ["c.wav"])
        with self.assertRaises(FileNotFoundError):
            ev.expand_paths([str(root / "missing")])
        with self.assertRaises(FileNotFoundError):
            ev.expand_paths([str(root / "*.flac")])

    def test_parse_thresholds(self):
        self.assertEqual(ev.parse_thresholds("0.7,0.3, 0.5"), [0.3, 0.5, 0.7])
        for bad in ["", "1.5", "a"]:
            with self.subTest(bad=bad):
                with self.assertRaises((ValueError, argparse.ArgumentTypeError)):
                    ev.parse_thresholds(bad)


class OwwScorerTest(unittest.TestCase):
    """OwwScorer against a stand-in for the openwakeword 0.6.0 API (no real model)."""

    def fake_openwakeword(self, root, predictions):
        pkg_dir = root / "openwakeword"
        (pkg_dir / "resources" / "models").mkdir(parents=True)
        created = {}

        class FakeModel:
            def __init__(self, wakeword_models=(), inference_framework="tflite", **kwargs):
                created.update(wakeword_models=wakeword_models, inference_framework=inference_framework, **kwargs)
                created["resets"] = 0

            def reset(self):
                created["resets"] += 1

            def predict(self, x):
                created["dtype"], created["len"] = x.dtype, len(x)
                return dict(predictions)

        pkg = types.ModuleType("openwakeword")
        pkg.__file__ = str(pkg_dir / "__init__.py")
        sub = types.ModuleType("openwakeword.model")
        sub.Model = FakeModel
        pkg.model = sub
        return pkg_dir, {"openwakeword": pkg, "openwakeword.model": sub}, created

    def test_loads_a_custom_onnx_model_and_reads_its_score(self):
        root = tmpdir(self)
        pkg_dir, modules, created = self.fake_openwakeword(root, {"hey_near": 0.42})
        models = pkg_dir / "resources" / "models"
        (models / "melspectrogram.onnx").write_bytes(b"")
        (models / "embedding_model.onnx").write_bytes(b"")
        model = root / "hey_near.onnx"
        model.write_bytes(b"")
        with mock.patch.dict(sys.modules, modules):
            scorer = ev.OwwScorer(model)
            self.assertAlmostEqual(scorer.score(np.zeros(ev.FRAME, dtype=np.int16)), 0.42)
            scorer.reset()
        self.assertEqual(created["wakeword_models"], [str(model)])
        self.assertEqual(created["inference_framework"], "onnx")
        self.assertEqual(created["melspec_model_path"], str(models / "melspectrogram.onnx"))
        self.assertEqual(created["embedding_model_path"], str(models / "embedding_model.onnx"))
        self.assertEqual((created["dtype"], created["len"], created["resets"]), (np.int16, ev.FRAME, 1))

    def test_explicit_feature_models_and_multi_class_output(self):
        root = tmpdir(self)
        _, modules, created = self.fake_openwakeword(root, {"near": 0.1, "other": 0.7})
        for name in ["mel.onnx", "emb.onnx", "m.onnx"]:
            (root / name).write_bytes(b"")
        with mock.patch.dict(sys.modules, modules):
            scorer = ev.OwwScorer(root / "m.onnx", root / "mel.onnx", root / "emb.onnx")
            self.assertAlmostEqual(scorer.score(np.zeros(ev.FRAME, dtype=np.int16)), 0.7)
        self.assertEqual(created["melspec_model_path"], str(root / "mel.onnx"))
        self.assertEqual(created["embedding_model_path"], str(root / "emb.onnx"))

    def test_missing_feature_models_say_how_to_get_them(self):
        root = tmpdir(self)
        _, modules, _ = self.fake_openwakeword(root, {})
        (root / "m.onnx").write_bytes(b"")
        with mock.patch.dict(sys.modules, modules):
            with self.assertRaises(FileNotFoundError) as ctx:
                ev.OwwScorer(root / "m.onnx")
        self.assertIn("download_models", str(ctx.exception))

    def test_missing_model_fails_before_importing_openwakeword(self):
        with mock.patch.dict(sys.modules):
            sys.modules.pop("openwakeword", None)
            with self.assertRaises(FileNotFoundError):
                ev.OwwScorer("/no/such/model.onnx")
            self.assertNotIn("openwakeword", sys.modules)


class CliTest(unittest.TestCase):
    def test_table_and_json_with_e4(self):
        root = tmpdir(self)
        (root / "pos").mkdir()
        synth.write_wav(root / "pos" / "a.wav", audio(0.8, [(0.3, 9000)]))
        synth.write_wav(root / "pos" / "b.wav", audio(0.8, [(0.3, 4000)]))
        synth.write_wav(root / "neg.wav", audio(30.0, [(5.0, 6000)]))
        e4 = make_e4(root)
        out = root / "res" / "r.json"
        argv = ["--pos", str(root / "pos"), "--neg", str(root / "neg.wav"), "--e4", str(e4),
                "--thresholds", "0.5,0.3", "--json", str(out)]
        with redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(ev.main(argv, scorer_factory=LevelScorer), 0)
        text = stdout.getvalue()
        self.assertIn("threshold", text)
        self.assertIn("E4 hits", text)
        lines = [line for line in text.splitlines() if line.strip().startswith(("0.30", "0.50"))]
        self.assertEqual(len(lines), 2, text)
        self.assertIn("(2/2)", lines[0])
        self.assertIn("(1/2)", lines[1])
        data = json.loads(out.read_text())
        self.assertEqual(data["thresholds"], [0.3, 0.5])
        self.assertEqual(data["clips"]["thresholds"][1]["missed"], [str(root / "pos" / "b.wav")])
        self.assertEqual(data["clips"]["thresholds"][0]["false_alarms"], 1)
        self.assertEqual(data["e4"]["positives"], 3)
        self.assertEqual(data["e4"]["thresholds"][0]["hits"], 3)

    def test_e4_only(self):
        root = tmpdir(self)
        e4 = make_e4(root)
        with redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(ev.main(["--e4", str(e4)], scorer_factory=LevelScorer), 0)
        self.assertIn("E4 session: 3 takes", stdout.getvalue())

    def test_needs_something_to_score_and_a_model(self):
        with mock.patch("sys.stderr", io.StringIO()):
            with self.assertRaises(SystemExit):
                ev.main([], scorer_factory=LevelScorer)
            with self.assertRaises(SystemExit):
                ev.main(["--neg", "x.wav"])

    def test_default_e4_dir_is_next_to_the_checkout(self):
        self.assertEqual(ev.DEFAULT_E4_DIR.parts[-3:], ("phase0", "data", "e4"))

    def test_openwakeword_is_imported_lazily(self):
        self.assertNotIn("openwakeword", sys.modules)


if __name__ == "__main__":
    unittest.main()
