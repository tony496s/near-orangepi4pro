import csv
import io
import json
import math
import os
import tempfile
import unittest
from contextlib import redirect_stderr
from itertools import islice
from pathlib import Path
from unittest import mock

import numpy as np

from near_wake import synth, texts, train

RECIPE = Path(__file__).resolve().parents[1] / "recipes" / "train.json"


def tmpdir(test):
    d = tempfile.TemporaryDirectory()
    test.addCleanup(d.cleanup)
    return Path(d.name)


def sine(seconds, amp=0.5, freq=440.0):
    t = np.arange(int(round(seconds * train.SAMPLE_RATE))) / train.SAMPLE_RATE
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def write_run(d, rows, missing=(), fields=("file", "voice", "text", "seconds")):
    """A synth run dir: one short WAV per row (text, seconds) plus manifest.csv; [missing] rows get no WAV."""
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "manifest.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(fields))
        w.writeheader()
        for i, (text, seconds) in enumerate(rows):
            name = f"clip_{i:05d}.wav"
            if i not in missing:
                synth.write_wav(d / name, sine(0.05))
            w.writerow({"file": name, "voice": "v", "text": text, "seconds": seconds})
    return d


def write_real(d, takes):
    """Real takes [(speaker, phrase)] like near_wake.record: 0.8 s silence, a 0.5 s burst, 1.5 s silence."""
    d.mkdir(parents=True, exist_ok=True)
    take = np.concatenate([np.zeros(12800), sine(0.5), np.zeros(24000)]).astype(np.float32)
    with open(d / "manifest.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["file", "speaker", "take", "index", "seconds", "phrase"])
        w.writeheader()
        for i, (speaker, phrase) in enumerate(takes):
            name = f"{speaker}_near_{i:03d}.wav" if phrase else f"{speaker}_office_free_{i:03d}.wav"
            synth.write_wav(d / name, take)
            w.writerow({"file": name, "speaker": speaker, "take": "near", "index": i, "seconds": "2.800",
                        "phrase": phrase})
    return d


def make_config(root, **over):
    """A validated config whose WAKE_DATA is [root]."""
    path = root / "cfg.json"
    path.write_text(json.dumps({"_comment": "test", **over}), encoding="utf-8")
    return train.load_config(path, env={"WAKE_DATA": str(root)})


def small_config(root, **over):
    """Clips under root/synth, real takes under root/real, two big negatives and a validation stream."""
    base = {
        "clips": {s: [f"synth/{s}/*"] for s in train.SPLITS},
        "negative_features": {"big": "neg/big.npy", "stream": "neg/stream.npy"},
        "n_per_class": {"big": 4, "stream": 32, "positive": 2, "adversarial_negative": 2},
        "false_positive_validation": "neg/val.npy",
        "rir_dirs": ["rir"],
        "background_dirs": ["bg"],
        "steps": 100,
        "threads": 1,
    }
    base.update(over)
    for d in ("rir", "bg"):
        (root / d).mkdir(exist_ok=True)
    return make_config(root, **base)


def fill_synth(root):
    write_run(root / "synth" / "positive_train" / "en", [("hey near", 0.6), ("hey nia", 0.7)])
    write_run(root / "synth" / "positive_train" / "vi", [("hây nia", 0.8)])
    write_run(root / "synth" / "positive_test" / "en", [("hey near", 0.6)])
    write_run(root / "synth" / "negative_train" / "en", [("hey there", 0.5), ("near me", 0.6)])
    write_run(root / "synth" / "negative_train" / "vi", [("hay này", 0.5), ("thầy này dạy hay lắm", 1.4),
                                                          ("hay nè", 0.5)])
    write_run(root / "synth" / "negative_test" / "vi", [("thầy nè", 0.5), ("cây này", 0.5)])


# ---------------------------------------------------------------------------------------------------------------
# Config

class ConfigTest(unittest.TestCase):
    def setUp(self):
        self.root = tmpdir(self)

    def test_defaults_and_comment_keys(self):
        cfg = make_config(self.root, _note="ignored", steps=1000)
        self.assertEqual(cfg["steps"], 1000)
        self.assertEqual(cfg["model_type"], "dnn")
        self.assertEqual(cfg["wake_data"], str(self.root.resolve()))
        self.assertNotIn("_note", cfg)
        self.assertNotIn("_comment", cfg)

    def test_recipe_loads_with_first_model_values(self):
        cfg = train.load_config(RECIPE, env={"WAKE_DATA": str(self.root)})
        self.assertEqual((cfg["model_type"], cfg["layer_size"], cfg["steps"]), ("dnn", 32, 50000))
        self.assertEqual(cfg["augmentation_rounds"], 1)
        self.assertEqual(cfg["n_per_class"], {"ACAV100M": 1024, "vi_speech": 512, "positive": 50,
                                              "adversarial_negative": 50})
        self.assertEqual((cfg["max_negative_weight"], cfg["target_fp_per_hour"]), (1500, 0.2))
        raw = json.loads(RECIPE.read_text(encoding="utf-8"))
        settings = [k for k in raw if not k.startswith("_")]
        self.assertEqual(set(settings), set(train.DEFAULTS), "the recipe states every setting")
        self.assertTrue(set(settings) <= set(raw["_comment"]), "every setting is explained")

    def test_wake_data_must_be_set_and_a_directory(self):
        path = self.root / "cfg.json"
        path.write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(train.ConfigError, "WAKE_DATA"):
            train.load_config(path, env={})
        with self.assertRaisesRegex(train.ConfigError, "not a directory"):
            train.load_config(path, env={"WAKE_DATA": str(self.root / "nope")})

    def test_paths_are_relative_to_wake_data(self):
        cfg = make_config(self.root)
        self.assertEqual(train.data_path(cfg, "a/b.npy"), self.root.resolve() / "a" / "b.npy")
        self.assertEqual(train.data_path(cfg, "/abs/x.npy"), Path("/abs/x.npy"))

    def test_bad_files(self):
        path = self.root / "cfg.json"
        path.write_text("{nope", encoding="utf-8")
        with self.assertRaises(train.ConfigError):
            train.load_config(path, env={"WAKE_DATA": str(self.root)})
        path.write_text("[]", encoding="utf-8")
        with self.assertRaisesRegex(train.ConfigError, "object"):
            train.load_config(path, env={"WAKE_DATA": str(self.root)})
        with self.assertRaises(train.ConfigError):
            train.load_config(self.root / "missing.json", env={"WAKE_DATA": str(self.root)})

    def test_invalid_values(self):
        cases = {
            "unknown key": ({"stepz": 10}, "unknown keys stepz"),
            "steps not a multiple of 10": ({"steps": 1005}, "steps"),
            "too few steps": ({"steps": 50}, "steps"),
            "bool is not an int": ({"layer_size": True}, "layer_size"),
            "model type": ({"model_type": "cnn"}, "model_type"),
            "exclusion word": ({"exclude_negative_texts": "everything"}, "exclude_negative_texts"),
            "exclusion match": ({"exclude_negative_match": "fuzzy"}, "exclude_negative_match"),
            "split missing": ({"clips": {"positive_train": ["a"]}}, "clips"),
            "empty split": ({"clips": {s: [] for s in train.SPLITS}}, "clips"),
            "class missing": ({"n_per_class": {"ACAV100M": 1, "positive": 1, "adversarial_negative": 1}},
                              "n_per_class"),
            "class reserved": ({"negative_features": {"positive": "x.npy"}}, "negative_features"),
            "zero per class": ({"n_per_class": {**train.DEFAULTS["n_per_class"], "positive": 0}}, "n_per_class"),
            "bad name": ({"name": "../up"}, "run name"),
            "max clips split": ({"max_clips": {"train": 5}}, "max_clips"),
            "test speakers": ({"real_test_speakers": "tony"}, "real_test_speakers"),
            "threads": ({"threads": 0}, "threads"),
            "weight": ({"max_negative_weight": 0.5}, "max_negative_weight"),
            "target": ({"target_fp_per_hour": 0}, "target_fp_per_hour"),
        }
        for label, (over, message) in cases.items():
            with self.subTest(label):
                with self.assertRaisesRegex(train.ConfigError, message):
                    make_config(self.root, **over)

    def test_object_values_replace_the_default_whole(self):
        cfg = make_config(self.root, negative_features={"val": "v.npy"},
                          n_per_class={"val": 64, "positive": 8, "adversarial_negative": 8})
        self.assertEqual(set(cfg["n_per_class"]), {"val", "positive", "adversarial_negative"})

    def test_mishearings_keyword(self):
        cfg = make_config(self.root, exclude_negative_texts="mishearings")
        self.assertEqual(train.negative_exclusions(cfg), texts.MISHEARINGS_VI)
        cfg = make_config(self.root, exclude_negative_texts=["hey there"])
        self.assertEqual(train.negative_exclusions(cfg), ["hey there"])

    def test_check_name(self):
        self.assertEqual(train.check_name("hey_near-v1.2"), "hey_near-v1.2")
        for bad in ("", "-x", "a/b", "a b", None):
            with self.subTest(bad=bad), self.assertRaises(train.ConfigError):
                train.check_name(bad)


# ---------------------------------------------------------------------------------------------------------------
# Clips

class ClipGatheringTest(unittest.TestCase):
    def setUp(self):
        self.root = tmpdir(self)
        fill_synth(self.root)

    def test_every_run_of_each_split(self):
        cfg = small_config(self.root)
        clips, stats = train.gather_clips(cfg)
        self.assertEqual([len(clips[s]) for s in train.SPLITS], [3, 5, 1, 2])
        self.assertEqual([Path(c.path).parent.name for c in clips["negative_train"]], ["en"] * 2 + ["vi"] * 3)
        self.assertEqual(clips["positive_train"][2].text, "hây nia")
        self.assertEqual(clips["positive_train"][2].seconds, 0.8)
        self.assertEqual(len(stats["negative_train"]["dirs"]), 2)

    def test_rows_without_a_wav_and_dirs_without_a_manifest_are_skipped(self):
        write_run(self.root / "synth" / "positive_train" / "slow", [("hây nia", 0.9), ("hây nia", 0.9)], missing={1})
        (self.root / "synth" / "positive_train" / "empty").mkdir()
        (self.root / "synth" / "positive_train" / "stray.wav").write_bytes(b"")
        clips, stats = train.gather_clips(small_config(self.root))
        self.assertEqual(len(clips["positive_train"]), 4)
        self.assertEqual(stats["positive_train"]["missing_wav"], 1)

    def test_glitches_longer_than_max_clip_seconds_are_dropped(self):
        write_run(self.root / "synth" / "positive_train" / "glitch", [("hây nia", 86.4), ("hây nia", 1.2)])
        clips, stats = train.gather_clips(small_config(self.root, max_clip_seconds=4.0))
        self.assertEqual(len(clips["positive_train"]), 4)
        self.assertEqual(stats["positive_train"]["too_long"], 1)
        clips, _ = train.gather_clips(small_config(self.root, max_clip_seconds=None))
        self.assertEqual(len(clips["positive_train"]), 5)

    def test_duration_from_the_wav_when_the_manifest_has_none(self):
        write_run(self.root / "synth" / "positive_train" / "noseconds", [("hây nia", "")])
        clips, stats = train.gather_clips(small_config(self.root, max_clip_seconds=0.01))
        self.assertEqual(stats["positive_train"]["too_long"], 4, "the 0.05 s WAV is measured")

    def test_mishearings_exclusion_drops_negatives_that_contain_them(self):
        clips, stats = train.gather_clips(small_config(self.root, exclude_negative_texts="mishearings"))
        self.assertEqual([c.text for c in clips["negative_train"]], ["hey there", "near me", "hay nè"])
        self.assertEqual([c.text for c in clips["negative_test"]], ["cây này"])
        self.assertEqual(stats["negative_train"]["excluded"], 2)
        self.assertEqual(stats["negative_train"]["excluded_texts"], {"hay này": 1, "thầy này dạy hay lắm": 1})
        self.assertEqual(len(clips["positive_train"]), 3, "positives are never excluded")

    def test_exact_match_keeps_sentences(self):
        clips, _ = train.gather_clips(small_config(self.root, exclude_negative_texts="mishearings",
                                                   exclude_negative_match="exact"))
        self.assertEqual([c.text for c in clips["negative_train"]],
                         ["hey there", "near me", "thầy này dạy hay lắm", "hay nè"])

    def test_without_exclusion_every_negative_stays(self):
        clips, stats = train.gather_clips(small_config(self.root))
        self.assertEqual(len(clips["negative_train"]), 5)
        self.assertEqual(stats["negative_train"]["excluded"], 0)

    def test_custom_exclusion_list(self):
        clips, _ = train.gather_clips(small_config(self.root, exclude_negative_texts=["Hey, there!"]))
        self.assertEqual([c.text for c in clips["negative_train"]][:1], ["near me"])

    def test_is_excluded(self):
        self.assertTrue(train.is_excluded("Hay này!", ["hay này"]))
        self.assertTrue(train.is_excluded("cái này hay đấy à", texts.MISHEARINGS_VI))
        self.assertFalse(train.is_excluded("hay nè", texts.MISHEARINGS_VI))
        self.assertFalse(train.is_excluded("hay nay", ["hay này"]), "tones matter")
        self.assertFalse(train.is_excluded("thầy này dạy hay", ["thầy này"], "exact"))
        self.assertTrue(train.is_excluded("Thầy này.", ["thầy này"], "exact"))

    def test_max_clips_is_a_seeded_sample_in_order(self):
        cfg = small_config(self.root, max_clips={"negative_train": 3})
        a, stats = train.gather_clips(cfg)
        b, _ = train.gather_clips(cfg)
        self.assertEqual(a["negative_train"], b["negative_train"])
        self.assertEqual(len(a["negative_train"]), 3)
        self.assertEqual(stats["negative_train"]["limited"], 2)
        paths = [c.path for c in a["negative_train"]]
        self.assertEqual(paths, sorted(paths))
        self.assertEqual(len(a["positive_train"]), 3, "other splits are not limited")

    def test_subsample_keeps_all_when_there_are_few(self):
        clips = [train.Clip(str(i)) for i in range(3)]
        self.assertEqual(train.subsample(clips, 5, "s"), clips)


class RealTakesTest(unittest.TestCase):
    def setUp(self):
        self.root = tmpdir(self)

    def test_read_real_skips_free_recordings_and_missing_files(self):
        d = write_real(self.root / "real", [("tony", "Hey Near"), ("tony", ""), ("lan", "Hey Near")])
        (d / "lan_near_002.wav").unlink()
        clips = train.read_real(d)
        self.assertEqual([(c.speaker, c.text) for c in clips], [("tony", "Hey Near")])
        self.assertEqual(train.read_real(self.root / "nothing"), [])

    def test_split_by_configured_speakers(self):
        clips = [train.Clip(f"{s}{i}", speaker=s) for s in ("tony", "lan", "minh") for i in range(2)]
        tr, te, held = train.split_by_speaker(clips, ["lan"])
        self.assertEqual(held, ["lan"])
        self.assertEqual({c.speaker for c in te}, {"lan"})
        self.assertEqual({c.speaker for c in tr}, {"tony", "minh"})
        self.assertEqual(len(tr) + len(te), len(clips))

    def test_automatic_split_is_deterministic_and_by_speaker(self):
        self.assertEqual(train.auto_test_speakers([]), [])
        self.assertEqual(train.auto_test_speakers(["tony", "tony"]), [], "one speaker: all takes train")
        two = train.auto_test_speakers(["tony", "lan"])
        self.assertEqual(len(two), 1)
        self.assertEqual(train.auto_test_speakers(["lan", "tony"]), two, "file order does not matter")
        ten = [f"s{i}" for i in range(10)]
        self.assertEqual(len(train.auto_test_speakers(ten)), 2)
        self.assertEqual(train.auto_test_speakers(list(reversed(ten))), train.auto_test_speakers(ten))
        clips = [train.Clip(f"{s}{i}", speaker=s) for s in ten for i in range(3)]
        tr, te, held = train.split_by_speaker(clips)
        self.assertEqual(held, train.auto_test_speakers(ten))
        self.assertFalse({c.speaker for c in tr} & {c.speaker for c in te})

    def test_trim_real_clip_drops_the_silence(self):
        d = write_real(self.root / "real", [("tony", "Hey Near")])
        dst = self.root / "out" / "t.wav"
        seconds = train.trim_real_clip(str(d / "tony_near_000.wav"), dst)
        self.assertAlmostEqual(seconds, 0.5 + 2 * train.REAL_TRIM_PAD_S, delta=0.02)
        self.assertAlmostEqual(train.wav_seconds(dst), seconds, places=3)
        self.assertEqual(train.trim_real_clip("ignored when the output exists", dst), seconds)

    def test_silent_take_is_skipped(self):
        src = self.root / "silent.wav"
        synth.write_wav(src, np.zeros(16000, dtype=np.float32))
        self.assertIsNone(train.trim_real_clip(str(src), self.root / "o.wav"))


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.root = tmpdir(self)
        fill_synth(self.root)

    def test_real_train_takes_are_repeated_and_test_speakers_go_to_positive_test(self):
        write_real(self.root / "real", [("tony", "Hey Near"), ("tony", "Hey Near"), ("lan", "Hey Near"),
                                        ("lan", "")])
        cfg = small_config(self.root, real_repeat=5, real_test_speakers=["lan"])
        plan = train.plan_clips(cfg, self.root / "trimmed")
        self.assertEqual(plan.counts["positive_train"]["clips"], 3 + 2 * 5)
        self.assertEqual(plan.counts["positive_train"]["real"], 2)
        self.assertEqual(plan.counts["positive_test"]["clips"], 1 + 1)
        self.assertEqual(plan.real_test_speakers, ["lan"])
        real = [p for p in plan.paths["positive_train"] if "/trimmed/" in p]
        self.assertEqual(len(real), 10)
        self.assertTrue(all(Path(p).is_file() for p in real), "trimmed copies are written")
        self.assertTrue(all(Path(p).name.startswith("tony") for p in real))

    def test_without_real_out_no_real_takes(self):
        write_real(self.root / "real", [("tony", "Hey Near")])
        plan = train.plan_clips(small_config(self.root))
        self.assertEqual(plan.counts["positive_train"]["clips"], 3)

    def test_rounds_and_a_seeded_shuffle(self):
        cfg = small_config(self.root, augmentation_rounds=2)
        a = train.plan_clips(cfg)
        b = train.plan_clips(cfg)
        self.assertEqual(a.paths, b.paths)
        self.assertEqual(len(a.paths["negative_train"]), 10)
        self.assertEqual(sorted(a.paths["negative_train"]),
                         sorted([c.path for c in train.gather_clips(cfg)[0]["negative_train"]] * 2))
        other = train.plan_clips(small_config(self.root, augmentation_rounds=2, seed=7))
        self.assertNotEqual(a.paths["negative_train"], other.paths["negative_train"])

    def test_total_length_from_positive_train(self):
        self.assertEqual(train.plan_clips(small_config(self.root)).total_length, 32000)
        write_run(self.root / "synth" / "positive_train" / "long", [("hây nia", 2.0)] * 9)
        self.assertEqual(train.plan_clips(small_config(self.root)).total_length, 44000)


class TotalLengthTest(unittest.TestCase):
    def test_openwakeword_rule(self):
        self.assertEqual(train.total_length_for([0.6, 0.65, 0.7]), 32000, "short phrases: the 2 s minimum")
        self.assertEqual(train.total_length_for([1.25]), 32000, "20000 + 12000 = 32000")
        self.assertEqual(train.total_length_for([1.5]), 32000, "24000 + 12000 = 36000 is within 4000: snapped")
        self.assertEqual(train.total_length_for([1.56]), 37000, "25000 (rounded) + 12000 = 37000")
        self.assertEqual(train.total_length_for([2.0, 2.0, 0.1]), 44000, "median, not mean")

    def test_no_clips(self):
        with self.assertRaises(ValueError):
            train.total_length_for([])


# ---------------------------------------------------------------------------------------------------------------
# Transforms

class TransformTest(unittest.TestCase):
    def test_windows_already_shaped_pass_through(self):
        x = np.random.rand(5, 16, 96).astype(np.float16)
        self.assertIs(train.negative_windows(x), x)

    def test_feature_stream_becomes_consecutive_windows(self):
        x = np.arange(40 * 96, dtype=np.float32).reshape(40, 96)
        w = train.negative_windows(x)
        self.assertEqual(w.shape, (2, 16, 96))
        np.testing.assert_array_equal(w[0], x[:16])
        np.testing.assert_array_equal(w[1], x[16:32])

    def test_an_exact_multiple_keeps_its_last_window(self):
        self.assertEqual(train.negative_windows(np.zeros((32, 96))).shape, (2, 16, 96))
        self.assertEqual(train.negative_windows(np.zeros((15, 96))).shape, (0, 16, 96))

    def test_rows_of_another_length_are_rewindowed(self):
        x = np.arange(3 * 32 * 96, dtype=np.float32).reshape(3, 32, 96)
        w = train.negative_windows(x)
        self.assertEqual(w.shape, (6, 16, 96))
        np.testing.assert_array_equal(w[1], x[0, 16:])
        np.testing.assert_array_equal(w[2], x[1, :16])

    def test_last_frames(self):
        x = np.random.rand(4, 16, 96)
        self.assertIs(train.last_frames(x), x)
        y = np.arange(2 * 20 * 3).reshape(2, 20, 3)
        np.testing.assert_array_equal(train.last_frames(y), y[:, 4:, :])
        with self.assertRaises(ValueError):
            train.last_frames(np.zeros((2, 10, 96)))
        with self.assertRaises(ValueError):
            train.last_frames(np.zeros((20, 96)))

    def test_label_transforms(self):
        lt = train.label_transforms(["ACAV100M", "vi_speech", "positive", "adversarial_negative"])
        self.assertEqual(lt["positive"](["positive"] * 3), [1, 1, 1])
        for c in ("ACAV100M", "vi_speech", "adversarial_negative"):
            with self.subTest(c):
                self.assertEqual(lt[c]([c] * 2), [0, 0])
        self.assertEqual(lt["positive"]([]), [])

    def test_data_transforms_and_sources(self):
        cfg = make_config(tmpdir(self))
        sources = train.feature_sources(cfg, Path("/f"))
        self.assertEqual(list(sources), ["ACAV100M", "vi_speech", "positive", "adversarial_negative"])
        self.assertEqual(sources["positive"], "/f/positive_features_train.npy")
        self.assertEqual(sources["adversarial_negative"], "/f/negative_features_train.npy")
        self.assertTrue(sources["ACAV100M"].endswith("openwakeword_features_ACAV100M_2000_hrs_16bit.npy"))
        dt = train.data_transforms(list(sources))
        self.assertIs(dt["ACAV100M"], train.negative_windows)
        self.assertIs(dt["positive"], train.last_frames)
        self.assertIs(dt["adversarial_negative"], train.last_frames)

    def test_windows_for_samples_matches_the_feature_frames(self):
        self.assertEqual(train.windows_for_samples(32000), 1, "2 s -> 197 mel frames -> 16 embeddings")
        self.assertEqual(train.windows_for_samples(16000), 0)
        n = 600 * 16000
        frames = (math.ceil(n / 160 - 3) - 76) // 8 + 1
        self.assertEqual(train.windows_for_samples(n), frames // 16)

    def test_false_positive_windows_slide_by_one_frame(self):
        stream = np.arange(20 * 96, dtype=np.float32).reshape(20, 96)
        fp = train.FalsePositiveWindows(stream, batch=2)
        self.assertEqual(len(fp), 5)
        batches = list(fp)
        self.assertEqual([tuple(x.shape) for x, _ in batches], [(2, 16, 96), (2, 16, 96), (1, 16, 96)])
        np.testing.assert_array_equal(batches[0][0][1].numpy(), stream[1:17])
        self.assertTrue(all(float(y.abs().sum()) == 0 for _, y in batches))
        self.assertAlmostEqual(fp.hours, 20 * 0.08 / 3600)
        with self.assertRaises(ValueError):
            train.FalsePositiveWindows(np.zeros((10, 96)))

    def test_npy_check_spots_a_partial_download(self):
        d = tmpdir(self)
        p = d / "a.npy"
        np.save(p, np.zeros((10, 16, 96), dtype=np.float16))
        self.assertEqual(train.check_npy(p, "a"), (10, 16, 96))
        data = p.read_bytes()
        p.write_bytes(data[:len(data) // 2])
        with self.assertRaisesRegex(train.StageError, "still downloading"):
            train.check_npy(p, "a")
        with self.assertRaisesRegex(train.StageError, "no "):
            train.check_npy(d / "b.npy", "b")


# ---------------------------------------------------------------------------------------------------------------
# Stages with the heavy parts faked

class FakeAugment:
    """Shaped like openwakeword.data.augment_clips: yields int16 batches of (batch, total_length)."""

    def __init__(self):
        self.calls = []

    def __call__(self, clip_paths, total_length, batch_size, background_clip_paths, RIR_paths):
        self.calls.append({"n": len(clip_paths), "total_length": total_length, "batch_size": batch_size,
                           "backgrounds": len(background_clip_paths), "rirs": len(RIR_paths)})
        for i in range(0, len(clip_paths), batch_size):
            yield np.zeros((len(clip_paths[i:i + batch_size]), total_length), dtype=np.int16)


class FakeCompute:
    """Shaped like compute_features_from_generator: writes (n_total, 16, 96) float32 to output_file."""

    def __init__(self):
        self.calls = []

    def __call__(self, generator, n_total, clip_duration, output_file, device, ncpu):
        rows = sum(len(b) for b in generator)
        self.calls.append({"n_total": n_total, "rows": rows, "file": output_file, "device": device, "ncpu": ncpu})
        with open(output_file, "wb") as f:
            np.save(f, np.full((n_total, 16, 96), len(self.calls), dtype=np.float32))


class FeaturesStageTest(unittest.TestCase):
    def setUp(self):
        self.root = tmpdir(self)
        fill_synth(self.root)
        (self.root / "rir").mkdir()
        synth.write_wav(self.root / "rir" / "r.wav", sine(0.1))
        (self.root / "bg" / "music").mkdir(parents=True)
        synth.write_wav(self.root / "bg" / "music" / "b.wav", sine(0.1))
        self.cfg = small_config(self.root, augmentation_batch_size=2)
        self.run_dir = self.root / "runs" / "t"

    def test_writes_four_feature_sets_and_a_summary(self):
        aug, comp = FakeAugment(), FakeCompute()
        out = train.run_features(self.cfg, self.run_dir, augment=aug, compute=comp)
        feat = self.run_dir / "features"
        for split, name in train.FEATURE_FILES.items():
            with self.subTest(split):
                self.assertTrue((feat / name).is_file())
                self.assertFalse((feat / (name + ".part")).exists())
                self.assertEqual(np.load(feat / name).shape[0], out["clips"][split]["clips"])
        self.assertEqual([c["n"] for c in aug.calls], [3, 5, 1, 2])
        self.assertEqual([c["batch_size"] for c in aug.calls], [2, 2, 1, 2], "never more than n_total")
        self.assertTrue(all(c["total_length"] == 32000 and c["rirs"] == 1 and c["backgrounds"] == 1
                            for c in aug.calls))
        self.assertTrue(all(c["device"] == "cpu" and c["ncpu"] == 1 for c in comp.calls))
        self.assertTrue(all(c["rows"] == c["n_total"] for c in comp.calls))
        summary = json.loads((feat / "features.json").read_text(encoding="utf-8"))
        self.assertEqual(summary["total_length"], 32000)
        self.assertEqual(summary["shapes"]["negative_train"], [5, 16, 96])
        self.assertEqual(out["computed"], list(train.SPLITS))

    def test_resumes_and_refuses_stale_features(self):
        train.run_features(self.cfg, self.run_dir, augment=FakeAugment(), compute=FakeCompute())
        comp = FakeCompute()
        out = train.run_features(self.cfg, self.run_dir, augment=FakeAugment(), compute=comp)
        self.assertEqual(comp.calls, [], "everything exists: skipped")
        self.assertEqual(out["computed"], [])
        write_run(self.root / "synth" / "negative_train" / "more", [("hey man", 0.5)])
        with self.assertRaisesRegex(train.StageError, "--overwrite"):
            train.run_features(self.cfg, self.run_dir, augment=FakeAugment(), compute=FakeCompute())
        comp = FakeCompute()
        train.run_features(self.cfg, self.run_dir, overwrite=True, augment=FakeAugment(), compute=comp)
        self.assertEqual(len(comp.calls), 4)

    def test_a_missing_split_stops_before_any_work(self):
        cfg = small_config(self.root, clips={**self.cfg["clips"], "negative_test": ["synth/none/*"]})
        comp = FakeCompute()
        with self.assertRaisesRegex(train.StageError, "negative_test"):
            train.run_features(cfg, self.run_dir, augment=FakeAugment(), compute=comp)
        self.assertEqual(comp.calls, [])

    def test_missing_rir_dir(self):
        cfg = small_config(self.root, rir_dirs=["nope"])
        with self.assertRaisesRegex(train.StageError, "nope"):
            train.run_features(cfg, self.run_dir, augment=FakeAugment(), compute=FakeCompute())


class ViSpeechStageTest(unittest.TestCase):
    def setUp(self):
        self.root = tmpdir(self)
        src = self.root / "negatives-vi" / "train"
        src.mkdir(parents=True)
        synth.write_wav(src / "a.wav", sine(5.0, amp=0.1))  # 5 s: 53 embedding frames -> 3 windows
        synth.write_wav(src / "b.wav", sine(2.0, amp=0.1))  # 2 s: 16 frames -> 1 window
        self.cfg = make_config(self.root)
        self.calls = []

    def embed(self, x):
        """(frames, 96) embeddings like openwakeword's, each frame holding its file's call index and frame index."""
        self.calls.append(len(x))
        n = (int(np.ceil(len(x) / 160 - 3)) - 76) // 8 + 1
        e = np.zeros((n, 96), dtype=np.float32)
        e[:, 0] = len(self.calls)
        e[:, 1] = np.arange(n)
        return e

    def test_builds_windows_like_acav100m(self):
        meta = train.build_vi_speech(self.cfg, embed=self.embed)
        out = self.root / "runs" / "features-vi-train.npy"
        arr = np.load(out, mmap_mode="r")
        self.assertEqual(arr.shape, (4, 16, 96))
        self.assertEqual(arr.dtype, np.float16)
        np.testing.assert_array_equal(arr[:, 0, 0], [1, 1, 1, 2])
        np.testing.assert_array_equal(arr[1, :, 1], np.arange(16, 32))
        self.assertEqual(meta["windows"], 4)
        self.assertTrue(meta["built"])
        self.assertAlmostEqual(meta["audio_hours"] * 3600, 7.0, delta=0.2)
        self.assertFalse(out.with_name(out.name + ".part").exists())
        self.assertEqual(self.calls, [79360, 32000], "cut to whole 80 ms frames before embedding")

    def test_built_once(self):
        train.build_vi_speech(self.cfg, embed=self.embed)
        synth.write_wav(self.root / "negatives-vi" / "train" / "c.wav", sine(3.0, amp=0.1))
        with self.assertLogs("near_wake.train", "WARNING") as logs:
            meta = train.build_vi_speech(self.cfg, embed=self.embed)
        self.assertFalse(meta["built"])
        self.assertEqual(len(self.calls), 2)
        self.assertIn("c.wav", "\n".join(logs.output))
        meta = train.build_vi_speech(self.cfg, overwrite=True, embed=self.embed)
        self.assertEqual(meta["windows"], 4 + 1, "3 s: 28 frames -> 1 window")

    def test_errors(self):
        synth.write_wav(self.root / "negatives-vi" / "train" / "c.wav", sine(1.0), sr=8000)
        with self.assertRaisesRegex(train.StageError, "16 kHz"):
            train.build_vi_speech(self.cfg, embed=self.embed)
        with self.assertRaisesRegex(train.StageError, "no .wav"):
            train.build_vi_speech(make_config(self.root, vi_speech_dir="nowhere"), embed=self.embed)


class FakeModel:
    """Shaped like openwakeword.train.Model: auto_train pulls a few batches and returns a small torch network."""

    instances = []

    def __init__(self, n_classes, input_shape, model_type, layer_dim, seconds_per_example):
        import torch

        self.args = {"n_classes": n_classes, "input_shape": input_shape, "model_type": model_type,
                     "layer_dim": layer_dim, "seconds_per_example": seconds_per_example}
        self.history = {"loss": [np.float32(0.25)]}
        torch.manual_seed(0)
        self.net = torch.nn.Sequential(torch.nn.Flatten(), torch.nn.Linear(16 * 96, 1), torch.nn.Sigmoid())
        FakeModel.instances.append(self)

    def auto_train(self, X_train, X_val, false_positive_val_data, steps, max_negative_weight, target_fp_per_hour):
        self.train_args = {"steps": steps, "max_negative_weight": max_negative_weight,
                           "target_fp_per_hour": target_fp_per_hour}
        self.batches = list(islice(X_train, 3))
        self.batches += list(islice(X_train, 2))  # a later sequence iterates again
        self.val = list(X_val)
        self.fp = list(false_positive_val_data)
        return self.net

    def export_model(self, model, model_name, output_dir):
        import torch

        torch.onnx.export(model, torch.rand(1, 16, 96), os.path.join(output_dir, model_name + ".onnx"),
                          opset_version=13, dynamo=False)


def fake_batch_generator(data_files, n_per_class, data_transform_funcs, label_transform_funcs):
    """Shaped like mmap_batch_generator: n_per_class rows of each file, transformed, then labelled."""
    data = {k: np.load(v, mmap_mode="r") for k, v in data_files.items()}
    fake_batch_generator.args = {"files": dict(data_files), "n_per_class": dict(n_per_class)}
    while True:
        xs, ys = [], []
        for label, n in n_per_class.items():
            x = data_transform_funcs[label](np.asarray(data[label][:n]))
            xs.append(x)
            ys.extend(label_transform_funcs[label]([label] * len(x)))
        yield np.vstack(xs), np.array(ys)


class TrainStageTest(unittest.TestCase):
    def setUp(self):
        self.root = tmpdir(self)
        self.cfg = small_config(self.root)
        self.run_dir = self.root / "runs" / "t"
        feat = self.run_dir / "features"
        feat.mkdir(parents=True)
        rng = np.random.default_rng(0)
        for split, n in (("positive_train", 6), ("negative_train", 6), ("positive_test", 5), ("negative_test", 4)):
            np.save(feat / train.FEATURE_FILES[split], rng.random((n, 20, 96), dtype=np.float32))
        (feat / "features.json").write_text(json.dumps({"total_length": 36000, "clips": {}}), encoding="utf-8")
        (self.root / "neg").mkdir()
        np.save(self.root / "neg" / "big.npy", rng.random((10, 16, 96)).astype(np.float16))
        np.save(self.root / "neg" / "stream.npy", rng.random((100, 96)).astype(np.float32))
        np.save(self.root / "neg" / "val.npy", rng.random((40, 96)).astype(np.float32))
        FakeModel.instances = []

    def run_train(self, **kw):
        with redirect_stderr(io.StringIO()):
            return train.run_train(self.cfg, self.run_dir, model_cls=FakeModel, batch_generator=fake_batch_generator,
                                   **kw)

    def test_trains_on_every_source_and_exports_hey_near(self):
        info = self.run_train()
        m = FakeModel.instances[-1]
        self.assertEqual(m.args["input_shape"], (16, 96))
        self.assertEqual((m.args["model_type"], m.args["layer_dim"], m.args["n_classes"]), ("dnn", 32, 1))
        self.assertAlmostEqual(m.args["seconds_per_example"], 1.28)
        self.assertEqual(m.train_args, {"steps": 100, "max_negative_weight": 1500, "target_fp_per_hour": 0.2})
        args = fake_batch_generator.args
        self.assertEqual(list(args["files"]), ["big", "stream", "positive", "adversarial_negative"])
        self.assertEqual(args["n_per_class"], {"big": 4, "stream": 32, "positive": 2, "adversarial_negative": 2})
        x, y = m.batches[0]
        self.assertEqual(tuple(x.shape), (4 + 2 + 2 + 2, 16, 96), "stream rows -> 2 windows; clips cropped")
        self.assertEqual(y.tolist(), [0] * 6 + [1, 1] + [0, 0])
        self.assertEqual(str(x.dtype), "torch.float32")
        self.assertEqual(len(m.batches), 5)
        (xv, yv), = m.val
        self.assertEqual(tuple(xv.shape), (9, 16, 96))
        self.assertEqual(yv.tolist(), [1.0] * 5 + [0.0] * 4)
        pos = np.load(self.run_dir / "features" / "positive_features_test.npy")
        np.testing.assert_array_equal(xv[0].numpy(), pos[0, -16:], "the last 16 frames, where the phrase ends")
        self.assertEqual(sum(len(b[0]) for b in m.fp), 40 - 15)
        model = self.run_dir / "hey_near.onnx"
        self.assertTrue(model.is_file())
        self.assertFalse((self.run_dir / ".export").exists())
        self.assertEqual(info["model"], str(model))
        self.assertEqual(info["total_length"], 36000)
        self.assertEqual(info["onnx"]["input_shape"], [1, 16, 96])
        self.assertLess(info["onnx"]["max_abs_diff_vs_torch"], 1e-5)
        self.assertEqual(info["device"], "cpu")
        self.assertEqual(info["steps_run"], 120)
        self.assertEqual(set(info["metrics"]), {"threshold", "positive_test_recall", "negative_test_false_accepts",
                                                "fp_windows_per_hour"})

    def test_existing_model_is_kept_unless_overwrite(self):
        (self.run_dir / "hey_near.onnx").write_bytes(b"old")
        self.assertIsNone(self.run_train())
        self.assertEqual(FakeModel.instances, [])
        self.assertIsNotNone(self.run_train(overwrite=True))
        self.assertNotEqual((self.run_dir / "hey_near.onnx").read_bytes(), b"old")

    def test_missing_inputs(self):
        (self.run_dir / "features" / "features.json").unlink()
        with self.assertRaisesRegex(train.StageError, "--stage features"):
            self.run_train()

    def test_missing_vi_speech_cache_names_the_stage(self):
        self.cfg = small_config(self.root, negative_features={"vi_speech": "runs/features-vi-train.npy"},
                                n_per_class={"vi_speech": 4, "positive": 2, "adversarial_negative": 2})
        with self.assertRaisesRegex(train.StageError, "--stage vi-negatives"):
            self.run_train()

    def test_step_log_counts_across_sequences(self):
        model = mock.Mock(history={"loss": [0.5], "val_recall": [np.array(0.75)]})
        steps = train.StepLog(range(100), model, total=10, every=2)
        with self.assertLogs("near_wake.train", "INFO") as logs:
            first = list(islice(steps, 3))
            second = list(islice(steps, 4))
        self.assertEqual(first, [0, 1, 2])
        self.assertEqual(second, [0, 1, 2, 3], "each pass iterates the batches anew")
        self.assertEqual(steps.step, 7)
        self.assertEqual(len(logs.output), 3)
        self.assertIn("step 6/10", logs.output[-1])
        self.assertIn("val recall 0.75", logs.output[-1])


class PrefetchTest(unittest.TestCase):
    def test_same_items_in_order(self):
        self.assertEqual(list(train.Prefetch(range(50), depth=3)), list(range(50)))
        self.assertEqual(list(train.Prefetch([])), [])

    def test_endless_source_is_read_ahead_by_depth_only(self):
        pulled = []

        def source():
            i = 0
            while True:
                pulled.append(i)
                yield i
                i += 1

        p = train.Prefetch(source(), depth=2)
        self.assertEqual(list(islice(p, 5)), [0, 1, 2, 3, 4])
        self.assertLessEqual(len(pulled), 5 + 2 + 1)

    def test_an_error_in_the_source_reaches_the_consumer(self):
        def source():
            yield 1
            raise RuntimeError("bad batch")

        p = train.Prefetch(source())
        self.assertEqual(next(p), 1)
        with self.assertRaisesRegex(RuntimeError, "bad batch"):
            next(p)
        self.assertEqual(list(p), [], "finished after the error")


class MainTest(unittest.TestCase):
    def setUp(self):
        self.root = tmpdir(self)
        self.config = self.root / "cfg.json"
        self.config.write_text(json.dumps({"name": "base", "threads": 2}), encoding="utf-8")
        self.env = mock.patch.dict(os.environ, {"WAKE_DATA": str(self.root)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(logging_cleanup)

    def main(self, *argv):
        with redirect_stderr(io.StringIO()):
            return train.main(["--config", str(self.config), *argv])

    def test_all_runs_the_stages_in_order_and_writes_run_json(self):
        order = []
        feats = {"clips": {"positive_train": {"clips": 3}}, "total_length": 32000, "real_test_speakers": [],
                 "seconds": {}, "computed": ["positive_train"]}
        with mock.patch.object(train, "run_features", side_effect=lambda *a, **k: order.append("f") or feats), \
                mock.patch.object(train, "build_vi_speech",
                                  side_effect=lambda *a, **k: order.append("v") or {"windows": 4, "built": True}), \
                mock.patch.object(train, "run_train",
                                  side_effect=lambda *a, **k: order.append("t") or {"model": "m"}) as rt:
            self.assertEqual(self.main("--stage", "all", "--name", "exp-1"), 0)
        self.assertEqual(order, ["f", "v", "t"])
        self.assertEqual(rt.call_args.args[1], self.root.resolve() / "runs" / "exp-1")
        run = json.loads((self.root / "runs" / "exp-1" / "run.json").read_text(encoding="utf-8"))
        self.assertEqual(run["name"], "exp-1")
        self.assertEqual(run["config"]["threads"], 2)
        self.assertEqual(run["train"], {"model": "m"})
        self.assertEqual(run["vi_speech"], {"windows": 4})
        self.assertEqual(set(run["timings"]), {"features_s", "vi_negatives_s", "train_s"})
        self.assertTrue((self.root / "runs" / "exp-1" / "train.log").is_file())
        self.assertEqual(os.environ["OMP_NUM_THREADS"], "2")

    def test_overwrite_never_rebuilds_the_shared_cache_from_all(self):
        with mock.patch.object(train, "run_features", return_value={"clips": {}, "total_length": 32000,
                                                                     "real_test_speakers": [], "seconds": {},
                                                                     "computed": []}), \
                mock.patch.object(train, "build_vi_speech", return_value={"built": False}) as vi, \
                mock.patch.object(train, "run_train", return_value=None):
            self.main("--stage", "all", "--overwrite")
            self.assertFalse(vi.call_args.kwargs["overwrite"])
            self.main("--stage", "vi-negatives", "--overwrite")
            self.assertTrue(vi.call_args.kwargs["overwrite"])

    def test_single_stage_and_stage_errors(self):
        with mock.patch.object(train, "run_features", side_effect=train.StageError("no clips")) as rf, \
                mock.patch.object(train, "run_train") as rt:
            self.assertEqual(self.main("--stage", "features"), 1)
        rf.assert_called_once()
        rt.assert_not_called()

    def test_config_errors_exit_2(self):
        with self.assertRaises(SystemExit) as e:
            self.main("--stage", "train", "--name", "a/b")
        self.assertEqual(e.exception.code, 2)
        with mock.patch.dict(os.environ, {"WAKE_DATA": ""}), self.assertRaises(SystemExit):
            self.main("--stage", "train")


def logging_cleanup():
    import logging

    root = logging.getLogger()
    for h in list(root.handlers):
        if getattr(h, "_near_wake", False):
            root.removeHandler(h)
            h.close()


if __name__ == "__main__":
    unittest.main()
