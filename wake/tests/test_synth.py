import csv
import io
import os
import sys
import tempfile
import unittest
import wave
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

import numpy as np

from near_wake import synth, texts

TTS_RATE = 22050  # what Piper voices produce


class FakeAudio:
    def __init__(self, samples, sample_rate):
        self.samples = samples
        self.sample_rate = sample_rate


class FakeTts:
    """Shaped like sherpa_onnx.OfflineTts: a 440 Hz burst between stretches of silence, at 22050 Hz."""

    def __init__(self, voice_dir, noise_scale, noise_scale_w, num_speakers=1, silent=False):
        self.voice_dir = voice_dir
        self.noise = (noise_scale, noise_scale_w)
        self.num_speakers = num_speakers
        self.sample_rate = TTS_RATE
        self.silent = silent
        self.calls = []

    def generate(self, text, sid=0, speed=1.0):
        self.calls.append((text, sid, speed))
        burst_s = (0.3 + 0.02 * len(text)) / speed
        t = np.arange(int(burst_s * TTS_RATE)) / TTS_RATE
        burst = 0.3 * np.sin(2 * np.pi * 440 * t) * (0.5 + 0.5 * (sid % 3) / 2)
        if self.silent:
            burst = np.zeros_like(burst)
        lead, tail = np.zeros(int(0.25 * TTS_RATE)), np.zeros(int(0.4 * TTS_RATE))
        return FakeAudio(list(np.concatenate([lead, burst, tail]).astype(np.float32)), TTS_RATE)


class FakeFactory:
    """Builds FakeTts objects and remembers each build. speakers: voice dir basename -> num_speakers."""

    def __init__(self, speakers=None, silent=False):
        self.speakers = speakers or {}
        self.silent = silent
        self.built = []

    def __call__(self, voice_dir, noise_scale, noise_scale_w):
        tts = FakeTts(voice_dir, noise_scale, noise_scale_w,
                      num_speakers=self.speakers.get(os.path.basename(voice_dir), 1), silent=self.silent)
        self.built.append(tts)
        return tts

    @property
    def generate_calls(self):
        return sum(len(t.calls) for t in self.built)


def tmpdir(test):
    d = tempfile.TemporaryDirectory()
    test.addCleanup(d.cleanup)
    return Path(d.name)


def rows(out):
    with open(out / synth.MANIFEST, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def wav_info(path):
    with wave.open(str(path), "rb") as w:
        return w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()


def sine(seconds, sr, freq=440.0, amp=0.5):
    t = np.arange(int(round(seconds * sr))) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


class ResampleTest(unittest.TestCase):
    def test_22050_to_16k_length(self):
        x = sine(1.0, TTS_RATE)
        expected = -(-len(x) * 320 // 441)  # ceil(len * 16000 / 22050)
        self.assertEqual(len(synth.resample(x, TTS_RATE, 16000)), expected)
        self.assertEqual(len(synth.resample_linear(x, TTS_RATE, 16000)), expected)

    def test_48k_to_16k_length(self):
        self.assertEqual(len(synth.resample(sine(0.5, 48000), 48000, 16000)), 8000)
        self.assertEqual(len(synth.resample_linear(sine(0.5, 48000), 48000, 16000)), 8000)

    def test_tone_keeps_its_pitch(self):
        y = synth.resample(sine(1.0, TTS_RATE, freq=440.0), TTS_RATE, 16000)
        crossings = np.count_nonzero(np.diff(np.signbit(y[100:-100]).astype(np.int8)))
        self.assertAlmostEqual(crossings / ((len(y) - 200) / 16000) / 2, 440.0, delta=5.0)

    def test_numpy_fallback_when_scipy_is_missing(self):
        x = sine(0.3, TTS_RATE)
        with mock.patch.object(synth, "_resample_poly", return_value=None):
            y = synth.resample(x, TTS_RATE, 16000)
        np.testing.assert_array_equal(y, synth.resample_linear(x, TTS_RATE, 16000))

    def test_linear_interpolation_values(self):
        y = synth.resample_linear(np.array([0.0, 1.0, 2.0, 3.0], dtype=np.float32), 2, 4)
        np.testing.assert_allclose(y[:7], [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0])
        self.assertEqual(len(y), 8)
        self.assertEqual(y[-1], 3.0, "past the last input sample the value is held")

    def test_same_rate_and_empty(self):
        x = sine(0.1, 16000)
        np.testing.assert_array_equal(synth.resample(x, 16000, 16000), x)
        self.assertEqual(len(synth.resample(np.zeros(0, dtype=np.float32), TTS_RATE, 16000)), 0)

    def test_scipy_is_used_when_importable(self):
        try:
            import scipy.signal  # noqa: F401
        except ImportError:
            self.assertIsNone(synth._resample_poly())
        else:
            self.assertIsNotNone(synth._resample_poly())


class TrimNormalizeTest(unittest.TestCase):
    def test_trim_keeps_the_sound_and_a_small_margin(self):
        burst = sine(0.5, 16000)
        x = np.concatenate([np.zeros(8000), burst, np.zeros(16000)]).astype(np.float32)
        y = synth.trim_silence(x, 16000, pad_s=0.01)
        self.assertLessEqual(abs(len(y) - (len(burst) + 320)), 2)
        self.assertGreater(np.abs(y[150:200]).max(), 0.0, "the burst starts right after the margin")

    def test_threshold_is_relative_to_the_peak(self):
        loud = sine(0.2, 16000, amp=0.5)
        faint = sine(0.2, 16000, amp=0.5 * 10 ** (-50 / 20))  # 50 dB below the peak: silence
        quiet = sine(0.2, 16000, amp=0.5 * 10 ** (-30 / 20))  # 30 dB below: part of the sound
        trimmed = synth.trim_silence(np.concatenate([loud, faint]), 16000, pad_s=0)
        self.assertLessEqual(len(trimmed), len(loud), "the faint tail is gone")
        self.assertGreater(len(trimmed), len(loud) - 50)
        kept = synth.trim_silence(np.concatenate([loud, quiet]), 16000, pad_s=0)
        self.assertGreater(len(kept), len(loud) + len(quiet) - 50)

    def test_silence_trims_to_nothing(self):
        self.assertEqual(len(synth.trim_silence(np.zeros(1000, dtype=np.float32))), 0)
        self.assertEqual(len(synth.trim_silence(np.zeros(0, dtype=np.float32))), 0)

    def test_normalize_to_peak(self):
        y = synth.normalize_peak(sine(0.1, 16000, amp=0.05), -2.0)
        self.assertAlmostEqual(20 * np.log10(np.abs(y).max()), -2.0, places=4)
        np.testing.assert_array_equal(synth.normalize_peak(np.zeros(10, dtype=np.float32), -2.0), np.zeros(10))

    def test_process_gives_trimmed_int16_at_16k_with_the_peak_in_range(self):
        audio = FakeTts("v", 0.667, 0.8).generate("hey near")
        raw = np.asarray(audio.samples, dtype=np.float32)
        clip = synth.process(raw, TTS_RATE, -1.7)
        self.assertEqual(clip.dtype, np.int16)
        self.assertLess(len(clip) / 16000, len(raw) / TTS_RATE - 0.5, "the 0.65 s of silence is gone")
        self.assertAlmostEqual(20 * np.log10(np.abs(clip).max() / 32767), -1.7, places=2)


class WavTest(unittest.TestCase):
    def test_round_trip(self):
        path = tmpdir(self) / "a.wav"
        x = (sine(0.25, 16000) * 32767).astype(np.int16)
        synth.write_wav(path, x)
        self.assertEqual(wav_info(path), (1, 2, 16000, len(x)))
        y, sr = synth.read_wav(path)
        self.assertEqual(sr, 16000)
        np.testing.assert_allclose(y, x / 32768.0, atol=1e-6)

    def test_float_input_is_converted(self):
        path = tmpdir(self) / "f.wav"
        synth.write_wav(path, np.array([0.0, 0.5, -1.0, 2.0], dtype=np.float32))
        y, _ = synth.read_wav(path)
        np.testing.assert_allclose(y, [0.0, 16384 / 32768, -32767 / 32768, 32767 / 32768], atol=1e-4)

    def test_stereo_48k_becomes_mono_16k(self):
        path = tmpdir(self) / "s.wav"
        left = (sine(0.5, 48000, amp=1.0) * 20000).astype("<i2")
        with wave.open(str(path), "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(48000)
            w.writeframes(np.stack([left, np.zeros_like(left)], axis=1).tobytes())
        y = synth.read_wav_16k(path)
        self.assertEqual(len(y), 8000)
        self.assertAlmostEqual(float(np.abs(y).max()), 10000 / 32768, delta=0.02)


class PlanTest(unittest.TestCase):
    def test_same_seed_and_index_same_choices(self):
        self.assertEqual(synth.plan_clip(5, 1, "hey near", 3, 3), synth.plan_clip(5, 1, "hey near", 3, 3))
        self.assertNotEqual(synth.plan_clip(5, 1, "hey near", 3, 3), synth.plan_clip(5, 2, "hey near", 3, 3))

    def test_choices_stay_in_range_and_cover_everything(self):
        plans = [synth.plan_clip(i, 0, "x", 3, len(synth.NOISE_SETTINGS)) for i in range(300)]
        self.assertTrue(all(0.8 <= p.speed <= 1.25 for p in plans))
        self.assertTrue(all(-3.0 <= p.peak_dbfs <= -1.0 for p in plans))
        self.assertTrue(all(0.0 <= p.speaker_u < 1.0 for p in plans))
        self.assertEqual({p.voice for p in plans}, {0, 1, 2})
        self.assertEqual({p.noise for p in plans}, set(range(len(synth.NOISE_SETTINGS))))
        self.assertGreater(max(p.speed for p in plans) - min(p.speed for p in plans), 0.35)

    def test_speaker_for(self):
        self.assertEqual(synth.speaker_for(0.999, 904), 903)
        self.assertEqual(synth.speaker_for(0.5, 904), 452)
        self.assertEqual(synth.speaker_for(0.7, 1), 0)
        self.assertEqual(synth.speaker_for(0.7, 0), 0, "a single-speaker model may report 0 speakers")

    def test_noise_settings_differ(self):
        self.assertGreaterEqual(len(set(synth.NOISE_SETTINGS)), 3)


class FindVoiceFilesTest(unittest.TestCase):
    def make(self, names, espeak=True):
        d = tmpdir(self) / "vits-piper-en_US-libritts_r-medium"
        d.mkdir()
        for n in names:
            (d / n).write_text("")
        if espeak:
            (d / "espeak-ng-data").mkdir()
        return d

    def test_piper_dir(self):
        d = self.make(["en_US-libritts_r-medium.onnx", "en_US-libritts_r-medium.onnx.json", "tokens.txt", "MODEL_CARD"])
        f = synth.find_voice_files(d)
        self.assertEqual(Path(f["model"]).name, "en_US-libritts_r-medium.onnx")
        self.assertEqual(Path(f["tokens"]).name, "tokens.txt")
        self.assertEqual(Path(f["data_dir"]).name, "espeak-ng-data")

    def test_prefers_the_full_model_over_int8(self):
        d = self.make(["a.int8.onnx", "b.onnx", "tokens.txt"])
        self.assertEqual(Path(synth.find_voice_files(d)["model"]).name, "b.onnx")

    def test_missing_parts_are_clear_errors(self):
        for names, espeak, part in [(["tokens.txt"], True, "onnx"), (["m.onnx"], True, "tokens"),
                                    (["m.onnx", "tokens.txt"], False, "espeak-ng-data")]:
            with self.subTest(part=part):
                with self.assertRaises(FileNotFoundError) as ctx:
                    synth.find_voice_files(self.make(names, espeak))
                self.assertIn(part, str(ctx.exception))
        with self.assertRaises(FileNotFoundError):
            synth.find_voice_files(tmpdir(self) / "nope")

    def test_sherpa_onnx_is_imported_lazily(self):
        self.assertNotIn("sherpa_onnx", sys.modules)


class SynthesizeTest(unittest.TestCase):
    VOICES = ["/voices/en-libritts", "/voices/vi-vivos"]
    SPEAKERS = {"en-libritts": 904, "vi-vivos": 1}

    def run_synth(self, out, n, seed=7, factory=None, set_name="positive-en"):
        factory = factory or FakeFactory(self.SPEAKERS)
        counts = synth.synthesize(self.VOICES, set_name, n, out, seed=seed, factory=factory, log=lambda m: None)
        return counts, factory

    def test_writes_named_16k_clips_and_a_manifest(self):
        out = tmpdir(self)
        counts, _ = self.run_synth(out, 6)
        self.assertEqual(counts, {"written": 6, "skipped": 0, "failed": 0})
        names = [f"positive-en_{i:05d}.wav" for i in range(6)]
        self.assertEqual(sorted(p.name for p in out.glob("*.wav")), names)
        manifest = rows(out)
        self.assertEqual([r["file"] for r in manifest], names)
        with open(out / synth.MANIFEST, encoding="utf-8") as f:
            self.assertEqual(f.readline().strip().split(","), synth.MANIFEST_FIELDS)
        for r in manifest:
            channels, width, sr, frames = wav_info(out / r["file"])
            self.assertEqual((channels, width, sr), (1, 2, 16000))
            self.assertAlmostEqual(float(r["seconds"]), frames / 16000, delta=0.0005 + 1e-9)  # rounded to ms
            self.assertIn(r["voice"], self.SPEAKERS)
            self.assertLess(int(r["speaker"]), self.SPEAKERS[r["voice"]])
            self.assertIn(r["text"], texts.POSITIVE_EN)
            self.assertTrue(0.8 <= float(r["speed"]) <= 1.25)
            self.assertIn((float(r["noise_scale"]), float(r["noise_scale_w"])), synth.NOISE_SETTINGS)
            self.assertEqual(r["seed"], "7")
            y, _ = synth.read_wav(out / r["file"])
            peak_db = 20 * np.log10(np.abs(y).max() * 32768 / 32767)
            self.assertTrue(-3.01 <= peak_db <= -0.99, peak_db)

    def test_texts_follow_variants(self):
        out = tmpdir(self)
        self.run_synth(out, 15, seed=3, set_name="adversarial-vi")
        self.assertEqual([r["text"] for r in rows(out)], texts.variants(texts.ADVERSARIAL_VI, 15, 3))
        self.assertTrue(all(r["file"].startswith("adversarial-vi_") for r in rows(out)))

    def test_same_seed_same_clips(self):
        a, b = tmpdir(self), tmpdir(self)
        self.run_synth(a, 8, seed=11)
        self.run_synth(b, 8, seed=11)
        self.assertEqual((a / synth.MANIFEST).read_bytes(), (b / synth.MANIFEST).read_bytes())
        for p in sorted(a.glob("*.wav")):
            self.assertEqual(p.read_bytes(), (b / p.name).read_bytes(), p.name)

    def test_other_seed_other_clips(self):
        a, b = tmpdir(self), tmpdir(self)
        self.run_synth(a, 8, seed=1)
        self.run_synth(b, 8, seed=2)
        strip = lambda rs: [{k: v for k, v in r.items() if k != "seed"} for r in rs]  # noqa: E731
        self.assertNotEqual(strip(rows(a)), strip(rows(b)))

    def test_choices_reach_the_tts(self):
        out = tmpdir(self)
        _, factory = self.run_synth(out, 10)
        calls = [(os.path.basename(t.voice_dir), t.noise, c) for t in factory.built for c in t.calls]
        for r in rows(out):
            noise = (float(r["noise_scale"]), float(r["noise_scale_w"]))
            self.assertIn((r["voice"], noise, (r["text"], int(r["speaker"]), float(r["speed"]))), calls)

    def test_one_tts_object_per_voice_and_noise_setting(self):
        _, factory = self.run_synth(tmpdir(self), 40)
        keys = [(t.voice_dir, t.noise) for t in factory.built]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertLessEqual(len(keys), len(self.VOICES) * len(synth.NOISE_SETTINGS))
        self.assertEqual(factory.generate_calls, 40)

    def test_resume_skips_finished_clips(self):
        fresh, resumed = tmpdir(self), tmpdir(self)
        self.run_synth(fresh, 6)
        self.run_synth(resumed, 4)
        before = {p.name: p.stat().st_mtime_ns for p in resumed.glob("*.wav")}
        counts, factory = self.run_synth(resumed, 6)
        self.assertEqual(counts, {"written": 2, "skipped": 4, "failed": 0})
        self.assertEqual(factory.generate_calls, 2)
        self.assertEqual({n: (resumed / n).stat().st_mtime_ns for n in before}, before, "finished clips untouched")
        self.assertEqual((resumed / synth.MANIFEST).read_bytes(), (fresh / synth.MANIFEST).read_bytes())
        for p in fresh.glob("*.wav"):
            self.assertEqual(p.read_bytes(), (resumed / p.name).read_bytes(), p.name)

    def test_nothing_to_do_builds_no_tts(self):
        out = tmpdir(self)
        self.run_synth(out, 3)
        counts, factory = self.run_synth(out, 3)
        self.assertEqual(counts["skipped"], 3)
        self.assertEqual(factory.built, [], "no model is loaded when every clip is there")

    def test_deleted_clip_is_redone_with_one_manifest_row(self):
        out = tmpdir(self)
        self.run_synth(out, 4)
        original = (out / "positive-en_00002.wav").read_bytes()
        (out / "positive-en_00002.wav").unlink()
        counts, _ = self.run_synth(out, 4)
        self.assertEqual(counts, {"written": 1, "skipped": 3, "failed": 0})
        self.assertEqual((out / "positive-en_00002.wav").read_bytes(), original)
        self.assertEqual(sorted(r["file"] for r in rows(out)), [f"positive-en_{i:05d}.wav" for i in range(4)])

    def test_clip_without_a_manifest_row_is_redone(self):
        out = tmpdir(self)
        self.run_synth(out, 3)
        kept = [r for r in rows(out) if r["file"] != "positive-en_00001.wav"]
        with open(out / synth.MANIFEST, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=synth.MANIFEST_FIELDS)
            w.writeheader()
            w.writerows(kept)
        counts, _ = self.run_synth(out, 3)
        self.assertEqual(counts, {"written": 1, "skipped": 2, "failed": 0})
        self.assertEqual(sorted(r["file"] for r in rows(out)), [f"positive-en_{i:05d}.wav" for i in range(3)])

    def test_silent_tts_output_is_reported_not_written(self):
        out = tmpdir(self)
        messages = []
        counts = synth.synthesize(self.VOICES, "positive-en", 2, out, seed=0,
                                  factory=FakeFactory(self.SPEAKERS, silent=True), log=messages.append)
        self.assertEqual(counts, {"written": 0, "skipped": 0, "failed": 2})
        self.assertEqual(list(out.glob("*.wav")), [])
        self.assertFalse((out / synth.MANIFEST).exists())
        self.assertEqual(len(messages), 2)

    def test_no_temporary_files_are_left(self):
        out = tmpdir(self)
        self.run_synth(out, 3)
        self.assertEqual(list(out.glob("*.tmp")), [])

    def test_unknown_set_and_no_voices(self):
        with self.assertRaises(KeyError):
            synth.synthesize(self.VOICES, "positive-fr", 1, tmpdir(self), factory=FakeFactory())
        with self.assertRaises(ValueError):
            synth.synthesize([], "positive-en", 1, tmpdir(self), factory=FakeFactory())


class CliTest(unittest.TestCase):
    def voice_dir(self, root, name):
        d = root / name
        (d / "espeak-ng-data").mkdir(parents=True)
        (d / f"{name}.onnx").write_text("")
        (d / "tokens.txt").write_text("")
        return d

    def test_cli_builds_sherpa_tts_per_voice_and_writes_clips(self):
        root = tmpdir(self)
        voices = [self.voice_dir(root, "vits-piper-vi_VN-vais1000-medium"),
                  self.voice_dir(root, "vits-piper-vi_VN-vivos-x_low")]
        built = []

        def fake_sherpa_tts(voice_dir, noise_scale, noise_scale_w, threads=1):
            built.append((Path(voice_dir).name, noise_scale, noise_scale_w, threads))
            return FakeTts(voice_dir, noise_scale, noise_scale_w, num_speakers=65)

        out = root / "out"
        argv = ["--voice", str(voices[0]), "--voice", str(voices[1]), "--texts", "positive-vi", "--n", "5",
                "--out", str(out), "--seed", "4", "--threads", "3"]
        with mock.patch.object(synth, "sherpa_tts", fake_sherpa_tts), redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(synth.main(argv), 0)
        self.assertIn("5 written", stdout.getvalue())
        self.assertEqual(len(list(out.glob("positive-vi_*.wav"))), 5)
        self.assertTrue(built and all(b[3] == 3 for b in built))
        self.assertTrue({r["voice"] for r in rows(out)} <= {v.name for v in voices})

    def test_cli_rejects_an_incomplete_voice_dir(self):
        root = tmpdir(self)
        bad = root / "bad"
        bad.mkdir()
        with self.assertRaises(FileNotFoundError):
            synth.main(["--voice", str(bad), "--texts", "positive-en", "--n", "1", "--out", str(root / "o")])

    def test_cli_rejects_an_unknown_text_set(self):
        with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", io.StringIO()):
            with self.assertRaises(SystemExit):
                synth.main(["--voice", "x", "--texts", "positive-fr", "--n", "1", "--out", "o"])


if __name__ == "__main__":
    unittest.main()
