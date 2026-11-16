"""Tests for near_wake.record. A fake recorder and scripted answers stand in for the mic and the keyboard."""

from __future__ import annotations

import io
import math
import subprocess
import tempfile
import threading
import unittest
from contextlib import redirect_stderr
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Sequence

from near_wake import record
from near_wake.record import (
    SAMPLE_RATE, ArecordRecorder, Console, FfmpegRecorder, Job, Manifest, RecordError, check_name,
    choose_backend, describe_condition, finalize, free_name, inside_git_work_tree, main, make_recorder, measure,
    next_index, parse_avfoundation_audio, read_wav, record_clip, run_free, run_takes, take_name, to_dbfs,
    warnings_for, write_wav,
)

FIXED_NOW = datetime(2026, 11, 16, 10, 30, 0, tzinfo=timezone.utc)
CUE_S = record.CUE_SECONDS  # recorded lead-in before "now"
TAKE_S = 2.0
CLIP_S = CUE_S + TAKE_S  # what each take really records

FFMPEG_LIST_OUTPUT = """\
[AVFoundation indev @ 0x7f9e1c004a00] AVFoundation video devices:
[AVFoundation indev @ 0x7f9e1c004a00] [0] FaceTime HD Camera
[AVFoundation indev @ 0x7f9e1c004a00] [1] Capture screen 0
[AVFoundation indev @ 0x7f9e1c004a00] AVFoundation audio devices:
[AVFoundation indev @ 0x7f9e1c004a00] [0] MacBook Pro Microphone
[AVFoundation indev @ 0x7f9e1c004a00] [1] USB Audio Device
[in#0 @ 0x600001c3c000] Error opening input: Input/output error
Error opening input file .
"""


def square(amplitude: int, seconds: float) -> List[int]:
    """A square wave at [amplitude]: peak and RMS both equal [amplitude]."""
    n = round(seconds * SAMPLE_RATE)
    return [amplitude if i % 2 == 0 else -amplitude for i in range(n)]


class FakeRecorder:
    """Writes a WAV made of given samples instead of opening a mic.

    Each call takes the next clip from [clips]: a list of samples is written as is, an int is the amplitude of a
    square wave of the asked length, an exception is raised. Once they run out it writes a normal-level square wave.
    """

    name = "fake"
    device_label = "fake-mic"

    def __init__(self, clips: Optional[Sequence[object]] = None) -> None:
        self.clips = list(clips or [])
        self.calls: List[tuple] = []
        self.threads: List[threading.Thread] = []

    def record(self, path: Path, seconds: float) -> None:
        self.calls.append((Path(path), seconds))
        self.threads.append(threading.current_thread())
        clip = self.clips.pop(0) if self.clips else 8000
        if isinstance(clip, BaseException):
            raise clip
        write_wav(path, square(clip, seconds) if isinstance(clip, int) else clip)


def scripted(answers: Sequence[str]):
    """An input() replacement that replays [answers], then signals end of input."""
    it = iter(answers)

    def ask(prompt: str = "") -> str:
        try:
            return next(it)
        except StopIteration:
            raise EOFError from None

    return ask


def make_console(answers: Sequence[str] = ()) -> Console:
    return Console(input=scripted(answers), out=io.StringIO(), err=io.StringIO(), sleep=lambda s: None,
                   now=lambda: FIXED_NOW)


def completed(cmd, code=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(cmd, code, stdout, stderr)


class TempDirTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()
        self.out = self.root / "rec"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def job(self, **kw) -> Job:
        args = dict(out_dir=self.out, speaker="tony", take="near", count=3, seconds=2.0)
        args.update(kw)
        return Job(**args)

    def manifest_rows(self) -> List[dict]:
        return Manifest(self.out / "manifest.csv").rows()

    def wavs(self) -> List[str]:
        return sorted(p.name for p in self.out.glob("*.wav"))

    def hidden(self) -> List[str]:
        return sorted(p.name for p in self.out.iterdir() if p.name.startswith("."))


class NamingTest(TempDirTest):
    def test_take_and_free_names(self) -> None:
        self.assertEqual(take_name("tony", "near", 3), "tony_near_003.wav")
        self.assertEqual(take_name("tony", "far-quiet", 1234), "tony_far-quiet_1234.wav")
        self.assertEqual(free_name("tony", "office", 1), "tony_office_free_001.wav")

    def test_next_index_starts_at_one(self) -> None:
        self.assertEqual(next_index(self.out, "tony", "near"), 1)  # directory does not exist yet
        self.out.mkdir()
        self.assertEqual(next_index(self.out, "tony", "near"), 1)

    def test_next_index_continues_after_highest_existing_file(self) -> None:
        self.out.mkdir()
        for name in ["tony_near_001.wav", "tony_near_002.wav", "tony_near_005.wav",
                     "tony_far_009.wav", "mai_near_007.wav", "tony_near_free_004.wav",
                     ".tony_near_008.rec.wav", "tony_near_006.txt", "tony_near_x.wav"]:
            (self.out / name).write_bytes(b"")
        self.assertEqual(next_index(self.out, "tony", "near"), 6)
        self.assertEqual(next_index(self.out, "tony", "far"), 10)
        self.assertEqual(next_index(self.out, "tony", "near", free=True), 5)
        self.assertEqual(next_index(self.out, "tony", "far", free=True), 1)

    def test_resume_numbers_new_takes_after_existing_ones(self) -> None:
        self.out.mkdir()
        write_wav(self.out / "tony_near_001.wav", square(8000, 2.0))
        write_wav(self.out / "tony_near_002.wav", square(8000, 2.0))
        console = make_console(["", ""])
        summary = run_takes(self.job(count=2), FakeRecorder(), console)
        self.assertEqual(self.wavs(), ["tony_near_001.wav", "tony_near_002.wav", "tony_near_003.wav",
                                       "tony_near_004.wav"])
        self.assertEqual(summary.kept, 2)
        self.assertIn("Resuming", console.out.getvalue())

    def test_describe_condition(self) -> None:
        self.assertIn("0.5 m", describe_condition("near"))
        far_quiet = describe_condition("far-quiet")
        self.assertIn("2 m", far_quiet)
        self.assertIn("quiet voice", far_quiet)
        self.assertEqual(describe_condition("office"), "office")


class NameValidationTest(unittest.TestCase):
    def test_accepts_safe_names(self) -> None:
        for name in ["tony", "user-2", "far-quiet", "a", "0", "x" * 32]:
            self.assertEqual(check_name(name), name)

    def test_rejects_unsafe_names(self) -> None:
        for name in ["", "Tony", "a_b", "a b", "../x", "a/b", "-x", "ngọc", "a.b", "x" * 33]:
            with self.assertRaises(ValueError, msg=name):
                check_name(name)

    def test_cli_rejects_bad_speaker_and_take(self) -> None:
        for argv in (["--out", "/nonexistent/x", "--speaker", "Tony", "--take", "near"],
                     ["--out", "/nonexistent/x", "--speaker", "tony", "--take", "near_1"]):
            with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit) as cm:
                main(argv, recorder_factory=lambda b, d: FakeRecorder(), console=make_console())
            self.assertEqual(cm.exception.code, 2)
            self.assertIn("a-z, 0-9", err.getvalue())


class LevelsTest(unittest.TestCase):
    def test_to_dbfs(self) -> None:
        self.assertAlmostEqual(to_dbfs(32768), 0.0)
        self.assertAlmostEqual(to_dbfs(16384), -6.0206, places=3)
        self.assertEqual(to_dbfs(0), record.SILENCE_DB)
        self.assertEqual(to_dbfs(1e-9), record.SILENCE_DB)  # floored, never -inf

    def test_measure_square_wave(self) -> None:
        s = measure(square(1000, 0.5))
        self.assertEqual(s.samples, 8000)
        self.assertEqual(s.peak, 1000)
        self.assertAlmostEqual(s.rms, 1000.0)
        self.assertAlmostEqual(s.peak_dbfs, 20 * math.log10(1000 / 32768), places=6)
        self.assertAlmostEqual(s.rms_dbfs, s.peak_dbfs, places=6)
        self.assertAlmostEqual(s.seconds, 0.5)

    def test_measure_uses_negative_peak_and_mixed_levels(self) -> None:
        s = measure([0, 100, -32768, 0])
        self.assertEqual(s.peak, 32768)
        self.assertAlmostEqual(s.peak_dbfs, 0.0)
        self.assertAlmostEqual(s.rms, math.sqrt((100 ** 2 + 32768 ** 2) / 4))

    def test_measure_silence_and_empty(self) -> None:
        self.assertEqual(measure([0] * 100).rms_dbfs, record.SILENCE_DB)
        empty = measure([])
        self.assertEqual((empty.samples, empty.peak, empty.rms), (0, 0, 0.0))

    def test_normal_level_has_no_warnings(self) -> None:
        self.assertEqual(warnings_for(measure(square(8000, 0.1))), [])
        self.assertEqual(warnings_for(measure(square(600, 0.1))), [])  # -34.7 dBFS: just above the line

    def test_quiet_warning_below_minus_35_dbfs(self) -> None:
        w = warnings_for(measure(square(500, 0.1)))  # -36.3 dBFS
        self.assertEqual(len(w), 1)
        self.assertTrue(w[0].startswith("too quiet"))
        self.assertIn("-36.3", w[0])

    def test_digital_silence_is_too_quiet(self) -> None:
        w = warnings_for(measure([0] * 1600))
        self.assertEqual(len(w), 1)
        self.assertTrue(w[0].startswith("too quiet"))
        self.assertIn("permission", w[0])

    def test_one_full_scale_sample_is_clipped(self) -> None:
        for v in (32767, -32767, -32768):
            w = warnings_for(measure([0] * 100 + [v] + [0] * 100))
            self.assertTrue(any(x.startswith("clipped") for x in w), v)

    def test_three_near_full_scale_samples_are_clipped(self) -> None:
        two = measure([1000] * 100 + [32500, -32500])
        three = measure([1000] * 100 + [32500, -32500, 32100])
        self.assertEqual(two.near_clip, 2)
        self.assertEqual(two.clipped, 0)
        self.assertEqual(warnings_for(two), [])
        self.assertEqual(three.near_clip, 3)
        self.assertEqual([x for x in warnings_for(three) if x.startswith("clipped")], warnings_for(three))
        self.assertEqual(len(warnings_for(three)), 1)

    def test_loud_but_unclipped_has_no_warning(self) -> None:
        self.assertEqual(warnings_for(measure(square(31000, 0.1))), [])

    def test_stats_from_chunks_match_one_pass(self) -> None:
        samples = square(3000, 0.3) + [32767, -12, 5]
        m = record.Meter()
        for i in range(0, len(samples), 777):
            m.add(record.array("h", samples[i:i + 777]))
        self.assertEqual(m.stats(), measure(samples))


class ManifestTest(TempDirTest):
    def setUp(self) -> None:
        super().setUp()
        self.out.mkdir()
        self.manifest = Manifest(self.out / "manifest.csv")

    def row(self, file: str, peak: str = "-10.0") -> dict:
        return {"file": file, "speaker": "tony", "take": "near", "index": "1", "seconds": "2.000", "peak_dbfs": peak,
                "rms_dbfs": "-20.0", "phrase": "Hey Near", "backend": "fake", "device": "fake-mic",
                "created_utc": "2026-11-16T10:30:00Z"}

    def lines(self) -> List[str]:
        return (self.out / "manifest.csv").read_text(encoding="utf-8").splitlines()

    def test_header_written_once(self) -> None:
        self.manifest.upsert(self.row("a.wav"))
        self.manifest.upsert(self.row("b.wav"))
        lines = self.lines()
        self.assertEqual(lines[0], ",".join(record.MANIFEST_FIELDS))
        self.assertEqual(sum(1 for l in lines if l.startswith("file,")), 1)
        self.assertEqual(len(lines), 3)

    def test_upsert_replaces_row_with_same_file(self) -> None:
        self.manifest.upsert(self.row("a.wav", "-10.0"))
        self.manifest.upsert(self.row("b.wav", "-11.0"))
        self.manifest.upsert(self.row("a.wav", "-3.0"))
        rows = self.manifest.rows()
        self.assertEqual([(r["file"], r["peak_dbfs"]) for r in rows], [("a.wav", "-3.0"), ("b.wav", "-11.0")])
        self.assertEqual(sum(1 for l in self.lines() if l.startswith("file,")), 1)

    def test_remove(self) -> None:
        self.manifest.upsert(self.row("a.wav"))
        self.manifest.upsert(self.row("b.wav"))
        self.assertTrue(self.manifest.remove("a.wav"))
        self.assertFalse(self.manifest.remove("missing.wav"))
        self.assertEqual([r["file"] for r in self.manifest.rows()], ["b.wav"])
        self.assertEqual(self.hidden(), [])  # the temp file of the rewrite is gone

    def test_phrase_with_comma_and_quote_round_trips(self) -> None:
        row = self.row("a.wav")
        row["phrase"] = 'Hey, "Near"'
        self.manifest.upsert(row)
        self.assertEqual(self.manifest.rows()[0]["phrase"], 'Hey, "Near"')

    def test_missing_manifest_has_no_rows(self) -> None:
        self.assertEqual(self.manifest.rows(), [])
        self.assertFalse(self.manifest.remove("a.wav"))
        self.assertFalse((self.out / "manifest.csv").exists())


class SessionTest(TempDirTest):
    def test_records_count_takes_with_exact_length_and_rows(self) -> None:
        console = make_console(["", "", ""])
        fake = FakeRecorder()
        summary = run_takes(self.job(), fake, console)
        self.assertEqual(self.wavs(), ["tony_near_001.wav", "tony_near_002.wav", "tony_near_003.wav"])
        for name in self.wavs():
            fmt, samples = read_wav(self.out / name)
            self.assertEqual(fmt, (1, 2, SAMPLE_RATE))
            self.assertEqual(len(samples), round(CLIP_S * SAMPLE_RATE))
        rows = self.manifest_rows()
        self.assertEqual([r["file"] for r in rows], self.wavs())
        self.assertEqual(rows[1], {
            "file": "tony_near_002.wav", "speaker": "tony", "take": "near", "index": "2", "seconds": f"{CLIP_S:.3f}",
            "peak_dbfs": f"{to_dbfs(8000):.1f}", "rms_dbfs": f"{to_dbfs(8000):.1f}", "phrase": "Hey Near",
            "backend": "fake", "device": "fake-mic", "created_utc": "2026-11-16T10:30:00Z"})
        self.assertEqual((summary.kept, summary.rerecorded, summary.deleted), (3, 0, 0))
        self.assertEqual([seconds for _, seconds in fake.calls], [CLIP_S] * 3)
        self.assertEqual(self.hidden(), [])

    def test_prompt_shows_count_condition_cue_and_phrase(self) -> None:
        console = make_console(["", ""])
        run_takes(self.job(count=2, take="far", phrase="Hey Near"), FakeRecorder(), console)
        text = console.out.getvalue()
        self.assertIn("(1/2) far: about 2 m from the mic", text)
        self.assertIn("(2/2)", text)
        self.assertIn("ready...", text)
        self.assertIn('now: say "Hey Near"', text)
        self.assertLess(text.index("ready..."), text.index("now:"))

    def test_cue_pauses_before_now(self) -> None:
        sleeps = []
        console = make_console([""])
        console.sleep = sleeps.append
        run_takes(self.job(count=1, cue_seconds=0.8), FakeRecorder(), console)
        self.assertEqual(sleeps, [0.8])

    def test_recorder_starts_before_now_is_printed(self) -> None:
        events: List[str] = []
        started = threading.Event()

        class Spy(FakeRecorder):
            def record(self, path, seconds):
                events.append("record")
                started.set()
                super().record(path, seconds)

        class LoggingConsole(Console):
            def say(self, text=""):
                events.append(text.strip())
                super().say(text)

        def cue_sleep(seconds):
            events.append("sleep")
            started.wait(2)  # real time passes during the cue: the recorder has had time to start

        console = LoggingConsole(input=scripted([""]), out=io.StringIO(), err=io.StringIO(), sleep=cue_sleep,
                                 now=lambda: FIXED_NOW)
        run_takes(self.job(count=1), Spy(), console)
        ready = events.index("ready...")
        now = next(i for i, e in enumerate(events) if e.startswith("now:"))
        self.assertLess(ready, events.index("record"))
        self.assertLess(events.index("record"), now)
        self.assertLess(events.index("sleep"), now)

    def test_clip_is_cue_plus_seconds_with_lead_in_kept(self) -> None:
        lead_in = [0] * 8000  # 0.5 s of silence before the word
        word = square(9000, 2.0)
        fake = FakeRecorder([lead_in + word])
        run_takes(self.job(count=1, cue_seconds=0.5, seconds=2.0), fake, make_console([""]))
        self.assertEqual([s for _, s in fake.calls], [2.5])
        _, samples = read_wav(self.out / "tony_near_001.wav")
        self.assertEqual(list(samples), lead_in + word)
        self.assertEqual(self.manifest_rows()[0]["seconds"], "2.500")

    def test_record_error_from_thread_is_reported_and_retried(self) -> None:
        console = make_console(["", ""])
        fake = FakeRecorder([RecordError("device busy")])
        summary = run_takes(self.job(count=1), fake, console)
        self.assertTrue(all(t is not threading.main_thread() for t in fake.threads))
        self.assertIn("! recording failed: device busy", console.out.getvalue())
        self.assertIn("[Enter] try again", console.out.getvalue())
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual(self.wavs(), ["tony_near_001.wav"])
        self.assertEqual(summary.kept, 1)
        self.assertEqual(self.hidden(), [])

    def test_other_errors_from_thread_are_raised(self) -> None:
        with self.assertRaises(ValueError):
            run_takes(self.job(count=1), FakeRecorder([ValueError("bug")]), make_console([""]))
        self.assertEqual(self.hidden(), [])

    def test_rerecord_overwrites_file_and_replaces_row(self) -> None:
        console = make_console(["r", ""])
        fake = FakeRecorder([8000, 2000])
        summary = run_takes(self.job(count=1), fake, console)
        self.assertEqual(self.wavs(), ["tony_near_001.wav"])
        _, samples = read_wav(self.out / "tony_near_001.wav")
        self.assertEqual(max(samples), 2000)  # the second take won
        rows = self.manifest_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["peak_dbfs"], f"{to_dbfs(2000):.1f}")
        self.assertEqual((summary.kept, summary.rerecorded, summary.deleted), (1, 1, 0))
        self.assertEqual(len(fake.calls), 2)

    def test_delete_removes_file_and_row(self) -> None:
        console = make_console(["d"])
        summary = run_takes(self.job(count=1), FakeRecorder(), console)
        self.assertEqual(self.wavs(), [])
        self.assertEqual(self.manifest_rows(), [])
        self.assertEqual((summary.kept, summary.rerecorded, summary.deleted), (0, 0, 1))

    def test_delete_keeps_other_rows_and_frees_the_number(self) -> None:
        console = make_console(["", "d", ""])
        summary = run_takes(self.job(count=3), FakeRecorder(), console)
        self.assertEqual(self.wavs(), ["tony_near_001.wav", "tony_near_002.wav"])
        self.assertEqual([r["file"] for r in self.manifest_rows()], self.wavs())
        self.assertEqual((summary.kept, summary.deleted), (2, 1))

    def test_rows_of_other_speakers_survive_a_rerecord(self) -> None:
        run_takes(self.job(count=1, speaker="mai"), FakeRecorder(), make_console([""]))
        run_takes(self.job(count=1), FakeRecorder(), make_console(["r", ""]))
        self.assertEqual([r["file"] for r in self.manifest_rows()], ["mai_near_001.wav", "tony_near_001.wav"])

    def test_quit_keeps_current_clip_and_stops(self) -> None:
        console = make_console(["", "q"])
        fake = FakeRecorder()
        summary = run_takes(self.job(count=5), fake, console)
        self.assertEqual(self.wavs(), ["tony_near_001.wav", "tony_near_002.wav"])
        self.assertEqual(len(self.manifest_rows()), 2)
        self.assertEqual(summary.kept, 2)
        self.assertEqual(len(fake.calls), 2)

    def test_end_of_input_quits(self) -> None:
        summary = run_takes(self.job(count=5), FakeRecorder(), make_console([""]))
        self.assertEqual(summary.kept, 2)  # the second clip was recorded, then input ended: kept, then quit

    def test_unknown_answer_asks_again(self) -> None:
        console = make_console(["x", "R", ""])
        summary = run_takes(self.job(count=1), FakeRecorder(), console)
        self.assertIn("type Enter, r, d, q", console.out.getvalue())
        self.assertEqual((summary.kept, summary.rerecorded), (1, 1))  # "R" counts as r

    def test_warnings_are_shown(self) -> None:
        clipped = square(8000, CLIP_S)
        clipped[100] = 32767
        console = make_console(["", ""])
        run_takes(self.job(count=2), FakeRecorder([300, clipped]), console)
        text = console.out.getvalue()
        self.assertIn("! too quiet", text)
        self.assertIn("! clipped", text)

    def test_recorder_failure_can_be_retried(self) -> None:
        console = make_console(["", ""])
        fake = FakeRecorder([RecordError("mic gone")])
        summary = run_takes(self.job(count=1), fake, console)
        self.assertIn("recording failed: mic gone", console.out.getvalue())
        self.assertEqual(self.wavs(), ["tony_near_001.wav"])
        self.assertEqual(len(self.manifest_rows()), 1)
        self.assertEqual(summary.kept, 1)
        self.assertEqual(self.hidden(), [])

    def test_recorder_failure_then_quit(self) -> None:
        summary = run_takes(self.job(count=3), FakeRecorder([RecordError("mic gone")]), make_console(["q"]))
        self.assertEqual(self.wavs(), [])
        self.assertEqual(self.manifest_rows(), [])
        self.assertEqual(summary.kept, 0)

    def test_failed_rerecord_keeps_previous_file_and_row(self) -> None:
        console = make_console(["r", "q"])
        fake = FakeRecorder([8000, RecordError("mic gone")])
        run_takes(self.job(count=1), fake, console)
        _, samples = read_wav(self.out / "tony_near_001.wav")
        self.assertEqual(max(samples), 8000)
        self.assertEqual(len(self.manifest_rows()), 1)

    def test_short_clip_is_padded_and_long_clip_is_trimmed(self) -> None:
        fake = FakeRecorder([[1000] * 31000, [1000] * 40000])
        run_takes(self.job(count=2, cue_seconds=0.0), fake, make_console(["", ""]))
        for name in self.wavs():
            _, samples = read_wav(self.out / name)
            self.assertEqual(len(samples), 32000, name)
        _, padded = read_wav(self.out / "tony_near_001.wav")
        self.assertEqual(list(padded[-1000:]), [0] * 1000)


class FinalizeTest(TempDirTest):
    def setUp(self) -> None:
        super().setUp()
        self.out.mkdir()
        self.raw = self.out / ".raw.wav"
        self.dest = self.out / "clip.wav"

    def test_too_short_is_an_error_and_writes_nothing(self) -> None:
        write_wav(self.raw, [1000] * 16000)
        with self.assertRaisesRegex(RecordError, "1.00 s, expected 2.00 s"):
            finalize(self.raw, self.dest, 32000)
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.hidden(), [".raw.wav"])  # only the input; no half-written output

    def test_wrong_format_is_an_error(self) -> None:
        import wave
        with wave.open(str(self.raw), "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(44100)
            w.writeframes(bytes(4 * 44100))
        with self.assertRaisesRegex(RecordError, "2 channel"):
            finalize(self.raw, self.dest, 32000)
        self.assertFalse(self.dest.exists())

    def test_not_a_wav_is_an_error(self) -> None:
        self.raw.write_bytes(b"not audio")
        with self.assertRaisesRegex(RecordError, "not a readable WAV"):
            finalize(self.raw, self.dest, 32000)

    def test_stats_cover_the_final_samples(self) -> None:
        write_wav(self.raw, [32767] + [100] * 40000)
        stats = finalize(self.raw, self.dest, 32000)
        self.assertEqual(stats, measure([32767] + [100] * 31999))

    def test_record_clip_removes_raw_file_on_failure(self) -> None:
        class Broken(FakeRecorder):
            def record(self, path, seconds):
                write_wav(path, [0] * 10)  # a partial file, then a crash
                raise RecordError("boom")

        with self.assertRaises(RecordError):
            record_clip(Broken(), self.dest, 2.0)
        self.assertEqual(self.hidden() + self.wavs(), [])


class CommandLineTest(TempDirTest):
    def test_ffmpeg_command(self) -> None:
        cmd = FfmpegRecorder().command(Path("/data/tony_near_001.wav"), 2.0)
        self.assertEqual(cmd, ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-i", ":0",
                               "-t", "2", "-ac", "1", "-ar", "16000", "-sample_fmt", "s16", "-y",
                               "/data/tony_near_001.wav"])

    def test_ffmpeg_device_and_fractional_seconds(self) -> None:
        self.assertEqual(FfmpegRecorder("1").command(Path("a.wav"), 1.5)[7:10], [":1", "-t", "1.5"])
        self.assertEqual(FfmpegRecorder(":2").device_label, ":2")
        self.assertEqual(FfmpegRecorder("MacBook Pro Microphone").device_label, ":MacBook Pro Microphone")
        self.assertEqual(FfmpegRecorder().command(Path("a.wav"), 1800.0)[9], "1800")

    def test_arecord_command(self) -> None:
        cmd = ArecordRecorder().command(Path("/data/tony_near_001.wav"), 2.0)
        self.assertEqual(cmd, ["arecord", "-q", "-D", "default", "-f", "S16_LE", "-r", "16000", "-c", "1",
                               "-d", "2", "/data/tony_near_001.wav"])

    def test_arecord_rounds_seconds_up_and_never_asks_for_zero(self) -> None:
        dev = "plughw:CARD=Device,DEV=0"
        self.assertEqual(ArecordRecorder(dev).command(Path("a.wav"), 2.5)[2:4], ["-D", dev])
        self.assertEqual(ArecordRecorder().command(Path("a.wav"), 2.5)[10:12], ["-d", "3"])
        self.assertEqual(ArecordRecorder().command(Path("a.wav"), 0.3)[10:12], ["-d", "1"])  # -d 0 = forever

    def test_list_commands(self) -> None:
        self.assertEqual(FfmpegRecorder().list_command(),
                         ["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""])
        self.assertEqual(ArecordRecorder().list_command(), ["arecord", "-l"])

    def test_arecord_output_is_trimmed_to_exact_length(self) -> None:
        self.out.mkdir()
        calls = []

        def run(cmd, **kw):
            calls.append((cmd, kw))
            seconds = int(cmd[cmd.index("-d") + 1])
            write_wav(Path(cmd[-1]), square(4000, seconds))  # arecord records whole seconds
            return completed(cmd)

        dest = self.out / "tony_near_001.wav"
        stats = record_clip(ArecordRecorder(run=run), dest, 2.5)
        _, samples = read_wav(dest)
        self.assertEqual(len(samples), 40000)
        self.assertEqual(stats.samples, 40000)
        cmd, kw = calls[0]
        self.assertTrue(cmd[0].endswith("arecord"))
        self.assertEqual(cmd[1:12], ArecordRecorder().command(dest, 2.5)[1:12])
        self.assertIs(kw["stdin"], subprocess.DEVNULL)  # the recorder must not read our keyboard
        self.assertEqual(self.hidden(), [])

    def test_recorder_exit_code_is_an_error(self) -> None:
        def run(cmd, **kw):
            return completed(cmd, 1, "", "[avfoundation] Input/output error\n")

        with self.assertRaisesRegex(RecordError, "code 1: .*Input/output error"):
            FfmpegRecorder(run=run).record(self.root / "a.wav", 2.0)

    def test_missing_tool_and_timeout_are_errors(self) -> None:
        def missing(cmd, **kw):
            raise FileNotFoundError(cmd[0])

        def hangs(cmd, **kw):
            raise subprocess.TimeoutExpired(cmd, kw["timeout"])

        with self.assertRaisesRegex(RecordError, "not found"):
            ArecordRecorder(run=missing).record(self.root / "a.wav", 2.0)
        with self.assertRaisesRegex(RecordError, "did not finish"):
            ArecordRecorder(run=hangs).record(self.root / "a.wav", 2.0)


class ListDevicesTest(unittest.TestCase):
    def test_parse_avfoundation_audio(self) -> None:
        self.assertEqual(parse_avfoundation_audio(FFMPEG_LIST_OUTPUT),
                         [(0, "MacBook Pro Microphone"), (1, "USB Audio Device")])
        self.assertEqual(parse_avfoundation_audio("nothing here"), [])

    def test_ffmpeg_lists_audio_inputs_only(self) -> None:
        def run(cmd, **kw):
            return completed(cmd, 1, "", FFMPEG_LIST_OUTPUT)  # ffmpeg exits 1 after listing

        console = make_console()
        code = main(["--list-devices", "--backend", "ffmpeg"],
                    recorder_factory=lambda b, d: FfmpegRecorder(d, run=run), console=console)
        self.assertEqual(code, 0)
        text = console.out.getvalue()
        self.assertIn("0: MacBook Pro Microphone", text)
        self.assertIn("1: USB Audio Device", text)
        self.assertNotIn("FaceTime", text)

    def test_arecord_prints_card_list(self) -> None:
        listing = "**** List of CAPTURE Hardware Devices ****\ncard 1: Device [USB Audio Device], device 0: USB Audio"

        def run(cmd, **kw):
            self.assertEqual(cmd[1:], ["-l"])
            return completed(cmd, 0, listing, "")

        console = make_console()
        code = main(["--list-devices"], recorder_factory=lambda b, d: ArecordRecorder(d, run=run), console=console,
                    platform="linux")
        self.assertEqual(code, 0)
        self.assertIn("card 1: Device", console.out.getvalue())

    def test_missing_tool_fails(self) -> None:
        def run(cmd, **kw):
            raise FileNotFoundError(cmd[0])

        console = make_console()
        code = main(["--list-devices"], recorder_factory=lambda b, d: ArecordRecorder(d, run=run), console=console,
                    platform="linux")
        self.assertEqual(code, 1)
        self.assertIn("not found", console.err.getvalue())


class BackendTest(unittest.TestCase):
    def test_auto_picks_by_platform(self) -> None:
        self.assertEqual(choose_backend("auto", "darwin"), "ffmpeg")
        self.assertEqual(choose_backend("auto", "linux"), "arecord")
        self.assertEqual(choose_backend("auto", "linux2"), "arecord")
        with self.assertRaises(ValueError):
            choose_backend("auto", "win32")

    def test_explicit_backend_wins(self) -> None:
        self.assertEqual(choose_backend("arecord", "darwin"), "arecord")
        self.assertEqual(choose_backend("ffmpeg", "linux"), "ffmpeg")

    def test_make_recorder(self) -> None:
        self.assertIsInstance(make_recorder("ffmpeg"), FfmpegRecorder)
        rec = make_recorder("arecord", "hw:1,0")
        self.assertIsInstance(rec, ArecordRecorder)
        self.assertEqual(rec.device_label, "hw:1,0")
        with self.assertRaises(ValueError):
            make_recorder("sox")

    def test_cli_auto_backend(self) -> None:
        for platform, expected in (("darwin", "ffmpeg"), ("linux", "arecord")):
            chosen = []

            def factory(backend, device):
                chosen.append((backend, device))
                return FfmpegRecorder(device, run=lambda cmd, **kw: completed(cmd, 1, "", FFMPEG_LIST_OUTPUT))

            main(["--list-devices", "--device", "1"], recorder_factory=factory, console=make_console(),
                 platform=platform)
            self.assertEqual(chosen, [(expected, "1")])

    def test_cli_unknown_platform_is_a_usage_error(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            main(["--list-devices"], recorder_factory=lambda b, d: FakeRecorder(), console=make_console(),
                 platform="win32")
        self.assertEqual(cm.exception.code, 2)


class GitRefusalTest(TempDirTest):
    def test_git_directory_above_is_detected(self) -> None:
        (self.root / ".git").mkdir()
        self.assertTrue(inside_git_work_tree(self.root / "a" / "b"))  # need not exist yet
        self.assertTrue(inside_git_work_tree(self.root))

    def test_git_file_of_a_worktree_is_detected(self) -> None:
        (self.root / "repo").mkdir()
        (self.root / "repo" / ".git").write_text("gitdir: /elsewhere/.git/worktrees/repo\n")
        self.assertTrue(inside_git_work_tree(self.root / "repo" / "data"))
        self.assertFalse(inside_git_work_tree(self.root / "other"))

    def test_plain_directory_is_fine(self) -> None:
        self.assertFalse(inside_git_work_tree(self.out))

    def test_falls_back_to_walk_when_git_is_missing(self) -> None:
        def no_git(cmd, **kw):
            raise FileNotFoundError("git")

        self.assertFalse(inside_git_work_tree(self.out, run=no_git))
        (self.root / ".git").mkdir()
        self.assertTrue(inside_git_work_tree(self.out, run=no_git))

    def test_git_rev_parse_is_trusted(self) -> None:
        calls = []

        def git_says_true(cmd, **kw):
            calls.append((cmd, kw["cwd"]))
            return completed(cmd, 0, "true\n", "")

        self.assertTrue(inside_git_work_tree(self.out / "x", run=git_says_true))
        self.assertEqual(calls, [(["git", "rev-parse", "--is-inside-work-tree"], str(self.root))])  # nearest existing

    def test_cli_refuses_and_creates_nothing(self) -> None:
        (self.root / ".git").mkdir()
        console = make_console([""])
        fake = FakeRecorder()
        code = main(["--out", str(self.out), "--speaker", "tony", "--take", "near", "--count", "1"],
                    recorder_factory=lambda b, d: fake, console=console, platform="darwin")
        self.assertEqual(code, 1)
        self.assertIn("inside a git work tree", console.err.getvalue())
        self.assertFalse(self.out.exists())
        self.assertEqual(fake.calls, [])


class FreeModeTest(TempDirTest):
    def test_free_recording_file_and_row(self) -> None:
        fake = FakeRecorder()
        summary = run_free(self.job(take="office"), 0.01, fake, make_console())
        self.assertEqual(self.wavs(), ["tony_office_free_001.wav"])
        _, samples = read_wav(self.out / "tony_office_free_001.wav")
        self.assertEqual(len(samples), round((CUE_S + 0.6) * SAMPLE_RATE))  # 0.01 min after the lead-in
        self.assertAlmostEqual(fake.calls[0][1], CUE_S + 0.6)
        row = self.manifest_rows()[0]
        self.assertEqual((row["file"], row["index"], row["seconds"], row["phrase"], row["take"]),
                         ("tony_office_free_001.wav", "1", f"{CUE_S + 0.6:.3f}", "", "office"))
        self.assertEqual(summary.kept, 1)

    def test_free_numbering_is_separate_from_takes(self) -> None:
        run_takes(self.job(count=1, take="office"), FakeRecorder(), make_console([""]))
        run_free(self.job(take="office"), 0.01, FakeRecorder(), make_console())
        run_free(self.job(take="office"), 0.01, FakeRecorder(), make_console())
        self.assertEqual(self.wavs(), ["tony_office_001.wav", "tony_office_free_001.wav",
                                       "tony_office_free_002.wav"])
        self.assertEqual(next_index(self.out, "tony", "office"), 2)
        self.assertEqual(len(self.manifest_rows()), 3)

    def test_cli_free_mode(self) -> None:
        console = make_console()
        code = main(["--out", str(self.out), "--speaker", "tony", "--take", "office", "--free", "--minutes", "0.01"],
                    recorder_factory=lambda b, d: FakeRecorder(), console=console, platform="darwin")
        self.assertEqual(code, 0)
        self.assertEqual(self.wavs(), ["tony_office_free_001.wav"])
        self.assertIn("kept 1, re-recorded 0, deleted 0", console.out.getvalue())

    def test_cli_free_failure_returns_error(self) -> None:
        console = make_console()
        code = main(["--out", str(self.out), "--speaker", "tony", "--take", "office", "--free", "--minutes", "0.01"],
                    recorder_factory=lambda b, d: FakeRecorder([RecordError("mic gone")]), console=console,
                    platform="darwin")
        self.assertEqual(code, 1)
        self.assertEqual(self.wavs(), [])
        self.assertEqual(self.manifest_rows(), [])

    def test_cli_free_needs_minutes_and_minutes_needs_free(self) -> None:
        base = ["--out", str(self.out), "--speaker", "tony", "--take", "office"]
        for extra in (["--free"], ["--minutes", "5"], ["--free", "--minutes", "0"], ["--free", "--minutes", "999"]):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
                main(base + extra, recorder_factory=lambda b, d: FakeRecorder(), console=make_console(),
                     platform="darwin")
            self.assertEqual(cm.exception.code, 2, extra)


class CliTest(TempDirTest):
    def argv(self, *extra: str) -> List[str]:
        return ["--out", str(self.out), "--speaker", "tony", "--take", "near", *extra]

    def test_full_run_prints_summary(self) -> None:
        console = make_console(["", "r", "", "d"])
        fake = FakeRecorder()
        code = main(self.argv("--count", "3", "--seconds", "1.5", "--phrase", "Hey Near"),
                    recorder_factory=lambda b, d: fake, console=console, platform="darwin")
        self.assertEqual(code, 0)
        self.assertEqual(self.wavs(), ["tony_near_001.wav", "tony_near_002.wav"])
        self.assertEqual([s for _, s in fake.calls], [CUE_S + 1.5] * 4)
        self.assertIn(f"kept 2, re-recorded 1, deleted 1; output: {self.out}", console.out.getvalue())
        _, samples = read_wav(self.out / "tony_near_001.wav")
        self.assertEqual(len(samples), round((CUE_S + 1.5) * SAMPLE_RATE))

    def test_ctrl_c_prints_summary_and_leaves_no_temp_files(self) -> None:
        console = make_console(["", ""])
        fake = FakeRecorder([8000, KeyboardInterrupt()])
        code = main(self.argv("--count", "3"), recorder_factory=lambda b, d: fake, console=console,
                    platform="darwin")
        self.assertEqual(code, 130)
        self.assertIn("kept 1, re-recorded 0, deleted 0", console.out.getvalue())
        self.assertEqual(self.wavs(), ["tony_near_001.wav"])
        self.assertEqual(self.hidden(), [])

    def test_usage_errors(self) -> None:
        for argv in ([], ["--speaker", "tony", "--take", "near"], self.argv("--count", "0"),
                     self.argv("--seconds", "-1"), self.argv("--seconds", "nan"), self.argv("--phrase", " "),
                     self.argv("--backend", "sox")):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
                main(argv, recorder_factory=lambda b, d: FakeRecorder(), console=make_console(), platform="darwin")
            self.assertEqual(cm.exception.code, 2, argv)

    def test_out_that_is_a_file_is_refused(self) -> None:
        self.out.write_text("x")
        console = make_console()
        code = main(self.argv(), recorder_factory=lambda b, d: FakeRecorder(), console=console, platform="darwin")
        self.assertEqual(code, 1)
        self.assertIn("not a directory", console.err.getvalue())

    def test_module_has_no_numpy_or_audioop(self) -> None:
        source = Path(record.__file__).read_text(encoding="utf-8")
        for banned in ("import numpy", "import audioop", "from audioop"):
            self.assertNotIn(banned, source)


if __name__ == "__main__":
    unittest.main()
