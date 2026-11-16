"""Record real "Hey Near" takes, and long free-speech or background files, for wake word training.

Standard library only, so it runs with the Mac's system python3 (ffmpeg + AVFoundation) and on the board (arecord).
Every file is a 16 kHz mono signed 16-bit WAV of an exact length. Recording starts at the "ready..." cue and the
speaker talks at "now", CUE_SECONDS later: the mic (AVFoundation can take a few hundred ms to open) is already running,
so the start of "Hey" is never lost. That lead-in stays in the clip, which is CUE_SECONDS + --seconds long (the same
for --free). Recordings are private: the tool refuses an output directory inside any git work tree.

    python3 -m near_wake.record --list-devices
    python3 -m near_wake.record --out ~/near-wake-data/real --speaker tony --take near --count 20
    python3 -m near_wake.record --out ~/near-wake-data/real --speaker tony --take office --free --minutes 30
"""

from __future__ import annotations

import argparse
import csv
import math
import operator
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import wave
from array import array
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, TextIO, Tuple

SAMPLE_RATE = 16000
FULL_SCALE = 32768
SILENCE_DB = -100.0

QUIET_PEAK_DBFS = -35.0
CLIP_LEVEL = 32767  # a sample at +-32767 (or -32768) is clipped
NEAR_CLIP_LEVEL = 32000  # about -0.2 dBFS
NEAR_CLIP_COUNT = 3  # this many samples near full scale also count as clipped

SHORT_TOLERANCE_S = 0.25  # a recorder may stop a little early: pad up to this much with silence, fail beyond it
CHUNK_SAMPLES = SAMPLE_RATE  # long files are copied and measured 1 s at a time
MAX_TAKE_SECONDS = 30.0
MAX_FREE_MINUTES = 240.0
CUE_SECONDS = 0.8  # recorded lead-in between "ready..." and "now"
STOP_WAIT_SECONDS = 5.0  # on Ctrl-C, how long to wait for the recorder thread to clean up its temp files

DEFAULT_PHRASE = "Hey Near"
NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
MANIFEST = "manifest.csv"
MANIFEST_FIELDS = ["file", "speaker", "take", "index", "seconds", "peak_dbfs", "rms_dbfs", "phrase", "backend",
                   "device", "created_utc"]
BACKENDS = ("auto", "ffmpeg", "arecord")
TOOL_DIRS = ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin")

# Parts of a take label (split on "-") that the prompt explains, e.g. "far-quiet".
CONDITION_HINTS = {
    "near": "about 0.5 m from the mic",
    "far": "about 2 m from the mic",
    "quiet": "quiet voice",
    "normal": "normal voice",
    "loud": "loud voice",
}


class RecordError(Exception):
    """The recorder failed, or gave audio we cannot use."""


# ----------------------------------------------------------------------------------------------------------------
# Names


def check_name(value: str, what: str = "name") -> str:
    """[value] if it is safe in a file name: 1-32 of a-z, 0-9 and '-', not starting with '-'."""
    if not NAME_RE.fullmatch(value):
        raise ValueError(f"{what} {value!r}: use 1-32 characters from a-z, 0-9 and '-', "
                         "starting with a letter or digit")
    return value


def take_name(speaker: str, take: str, index: int) -> str:
    return f"{speaker}_{take}_{index:03d}.wav"


def free_name(speaker: str, take: str, index: int) -> str:
    return f"{speaker}_{take}_free_{index:03d}.wav"


def next_index(out_dir: Path, speaker: str, take: str, free: bool = False) -> int:
    """One past the highest number already used by this speaker and take, so a run can be resumed."""
    prefix = f"{speaker}_{take}_" + ("free_" if free else "")
    pattern = re.compile(re.escape(prefix) + r"(\d{3,})\.wav")
    best = 0
    if out_dir.is_dir():
        for p in out_dir.iterdir():
            m = pattern.fullmatch(p.name)
            if m:
                best = max(best, int(m.group(1)))
    return best + 1


def describe_condition(take: str) -> str:
    hints = [CONDITION_HINTS[part] for part in take.split("-") if part in CONDITION_HINTS]
    return f"{take}: {', '.join(hints)}" if hints else take


# ----------------------------------------------------------------------------------------------------------------
# Privacy


def inside_git_work_tree(path: Path, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> bool:
    """True when [path] (which may not exist yet) is inside a git work tree or a .git directory."""
    path = Path(path).expanduser().resolve()
    for p in (path, *path.parents):
        if os.path.lexists(p / ".git"):  # a directory in a clone, a file in a worktree or submodule
            return True
    base = path
    while not base.exists() and base.parent != base:
        base = base.parent
    try:
        r = run(["git", "rev-parse", "--is-inside-work-tree"], cwd=str(base), stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False  # no git here: the walk above is the check
    return r.returncode == 0 and r.stdout.strip() == "true"


# ----------------------------------------------------------------------------------------------------------------
# Levels


def to_dbfs(level: float) -> float:
    """A sample level (0..32768) in dBFS, SILENCE_DB for zero."""
    if level <= 0:
        return SILENCE_DB
    return max(SILENCE_DB, 20 * math.log10(level / FULL_SCALE))


@dataclass(frozen=True)
class Stats:
    samples: int
    peak: int  # largest absolute sample, 0..32768
    rms: float
    clipped: int  # samples at full scale
    near_clip: int  # samples at or above NEAR_CLIP_LEVEL, full scale included

    @property
    def seconds(self) -> float:
        return self.samples / SAMPLE_RATE

    @property
    def peak_dbfs(self) -> float:
        return to_dbfs(self.peak)

    @property
    def rms_dbfs(self) -> float:
        return to_dbfs(self.rms)


class Meter:
    """Peak, RMS and clip counts over audio that arrives in chunks."""

    def __init__(self) -> None:
        self.n = 0
        self.peak = 0
        self.sumsq = 0
        self.clipped = 0
        self.near_clip = 0

    def add(self, chunk: Sequence[int]) -> None:
        if not chunk:
            return
        p = max(max(chunk), -min(chunk))
        self.peak = max(self.peak, p)
        self.sumsq += sum(map(operator.mul, chunk, chunk))
        if p >= NEAR_CLIP_LEVEL:
            self.near_clip += sum(1 for v in chunk if v >= NEAR_CLIP_LEVEL or v <= -NEAR_CLIP_LEVEL)
            self.clipped += sum(1 for v in chunk if v >= CLIP_LEVEL or v <= -CLIP_LEVEL)
        self.n += len(chunk)

    def stats(self) -> Stats:
        rms = math.sqrt(self.sumsq / self.n) if self.n else 0.0
        return Stats(self.n, self.peak, rms, self.clipped, self.near_clip)


def measure(samples: Iterable[int]) -> Stats:
    m = Meter()
    m.add(array("h", samples))
    return m.stats()


def warnings_for(stats: Stats) -> List[str]:
    out = []
    if stats.peak == 0:
        out.append("too quiet: no signal at all (digital silence); check --device and the terminal's microphone "
                   "permission")
    elif stats.peak_dbfs < QUIET_PEAK_DBFS:
        out.append(f"too quiet: peak {stats.peak_dbfs:.1f} dBFS is below {QUIET_PEAK_DBFS:.0f} dBFS; "
                   "move closer or speak up")
    if stats.clipped or stats.near_clip >= NEAR_CLIP_COUNT:
        out.append(f"clipped: {stats.clipped} samples at full scale, {stats.near_clip} near it; "
                   "move back or speak softer")
    return out


# ----------------------------------------------------------------------------------------------------------------
# WAV files


def _to_array(data: bytes) -> array:
    a = array("h")
    a.frombytes(data[: len(data) - len(data) % 2])
    if sys.byteorder == "big":
        a.byteswap()
    return a


def _to_bytes(samples: Iterable[int]) -> bytes:
    a = array("h", samples)
    if sys.byteorder == "big":
        a.byteswap()
    return a.tobytes()


def write_wav(path: Path, samples: Iterable[int]) -> None:
    """A 16 kHz mono s16 WAV of [samples]."""
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(_to_bytes(samples))


def read_wav(path: Path) -> Tuple[Tuple[int, int, int], array]:
    """((channels, sample width, rate), samples) of a 16-bit WAV."""
    with wave.open(str(path), "rb") as w:
        fmt = (w.getnchannels(), w.getsampwidth(), w.getframerate())
        return fmt, _to_array(w.readframes(w.getnframes()))


def finalize(raw: Path, dest: Path, expected: int) -> Stats:
    """Checks that [raw] is 16 kHz mono s16, cuts or pads it to exactly [expected] samples, writes [dest], measures it.

    [dest] is replaced in one step, so a failure leaves an older file (re-recording) untouched.
    """
    try:
        src = wave.open(str(raw), "rb")
    except (wave.Error, EOFError, OSError) as e:
        raise RecordError(f"recorder output is not a readable WAV ({e})") from None
    tmp = dest.with_name(f".{dest.stem}.out.wav")
    meter = Meter()
    try:
        with src:
            fmt = (src.getnchannels(), src.getsampwidth(), src.getframerate())
            if fmt != (1, 2, SAMPLE_RATE):
                raise RecordError(f"recorder gave {fmt[0]} channel(s), {8 * fmt[1]}-bit, {fmt[2]} Hz; "
                                  f"expected mono 16-bit {SAMPLE_RATE} Hz")
            with wave.open(str(tmp), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(SAMPLE_RATE)
                left = expected
                while left > 0:
                    data = src.readframes(min(CHUNK_SAMPLES, left))
                    if not data:
                        break
                    chunk = _to_array(data)
                    meter.add(chunk)
                    out.writeframes(data[: 2 * len(chunk)])
                    left -= len(chunk)
                if left > SHORT_TOLERANCE_S * SAMPLE_RATE:
                    raise RecordError(f"recorder gave {(expected - left) / SAMPLE_RATE:.2f} s, "
                                      f"expected {expected / SAMPLE_RATE:.2f} s")
                if left > 0:
                    meter.add(array("h", bytes(2 * left)))
                    out.writeframes(bytes(2 * left))
        os.replace(tmp, dest)
    finally:
        if tmp.exists():
            tmp.unlink()
    return meter.stats()


# ----------------------------------------------------------------------------------------------------------------
# Recorders


def find_tool(name: str) -> str:
    """[name] on PATH, else in the usual Homebrew and system directories, else [name] unchanged."""
    found = shutil.which(name)
    if found:
        return found
    for d in TOOL_DIRS:
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return name


def _format_seconds(seconds: float) -> str:
    return f"{seconds:.3f}".rstrip("0").rstrip(".")


def whole_seconds(seconds: float) -> int:
    """arecord's -d takes whole seconds (and 0 means forever): record at least [seconds], then trim."""
    return max(1, math.ceil(seconds - 1e-9))


class Recorder:
    """Records [seconds] of 16 kHz mono s16 audio into a WAV at [path]; finalize() then fixes the exact length.

    Anything with `name`, `device_label` and `record(path, seconds)` works (tests use a fake).
    """

    name = "?"

    def __init__(self, device: Optional[str] = None,
                 run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
        self.device = device or None
        self._run = run

    @property
    def device_label(self) -> str:
        raise NotImplementedError

    def command(self, path: Path, seconds: float) -> List[str]:
        raise NotImplementedError

    def list_command(self) -> List[str]:
        raise NotImplementedError

    def run_tool(self, cmd: List[str], timeout: float) -> subprocess.CompletedProcess:
        cmd = [find_tool(cmd[0])] + cmd[1:]
        try:
            # stdin is closed so ffmpeg cannot swallow the keys typed at our prompt.
            return self._run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             universal_newlines=True, errors="replace", timeout=timeout)
        except FileNotFoundError:
            raise RecordError(f"{cmd[0]} not found; install it or pick another --backend") from None
        except subprocess.TimeoutExpired:
            raise RecordError(f"{self.name} did not finish within {timeout:.0f} s") from None

    def record(self, path: Path, seconds: float) -> None:
        r = self.run_tool(self.command(path, seconds), timeout=seconds + 30)
        if r.returncode != 0:
            detail = (r.stderr or r.stdout or "").strip().splitlines()
            raise RecordError(f"{self.name} exited with code {r.returncode}" + (f": {detail[-1]}" if detail else ""))


class FfmpegRecorder(Recorder):
    """ffmpeg reading AVFoundation (macOS). --device is the audio device index or name from --list-devices."""

    name = "ffmpeg"

    @property
    def device_label(self) -> str:
        d = self.device or "0"
        return d if d.startswith(":") else ":" + d

    def command(self, path: Path, seconds: float) -> List[str]:
        return ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-i", self.device_label,
                "-t", _format_seconds(seconds), "-ac", "1", "-ar", str(SAMPLE_RATE), "-sample_fmt", "s16",
                "-y", str(path)]

    def list_command(self) -> List[str]:
        return ["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""]


class ArecordRecorder(Recorder):
    """arecord from ALSA (the board). --device is an ALSA PCM such as plughw:CARD=Device,DEV=0."""

    name = "arecord"

    @property
    def device_label(self) -> str:
        return self.device or "default"

    def command(self, path: Path, seconds: float) -> List[str]:
        return ["arecord", "-q", "-D", self.device_label, "-f", "S16_LE", "-r", str(SAMPLE_RATE), "-c", "1",
                "-d", str(whole_seconds(seconds)), str(path)]

    def list_command(self) -> List[str]:
        return ["arecord", "-l"]


def choose_backend(name: str, platform: str = sys.platform) -> str:
    if name != "auto":
        return name
    if platform == "darwin":
        return "ffmpeg"
    if platform.startswith("linux"):
        return "arecord"
    raise ValueError(f"no default backend for platform {platform!r}; pass --backend ffmpeg or --backend arecord")


def make_recorder(backend: str, device: Optional[str] = None) -> Recorder:
    if backend == "ffmpeg":
        return FfmpegRecorder(device)
    if backend == "arecord":
        return ArecordRecorder(device)
    raise ValueError(f"unknown backend {backend!r}")


def parse_avfoundation_audio(text: str) -> List[Tuple[int, str]]:
    """(index, name) of the audio inputs in ffmpeg's `-list_devices true` output."""
    devices = []
    in_audio = False
    for line in text.splitlines():
        if "AVFoundation audio devices" in line:
            in_audio = True
        elif "AVFoundation video devices" in line:
            in_audio = False
        elif in_audio:
            m = re.search(r"\] \[(\d+)\] (.+?)\s*$", line)
            if m:
                devices.append((int(m.group(1)), m.group(2)))
    return devices


# ----------------------------------------------------------------------------------------------------------------
# Manifest


class Manifest:
    """DIR/manifest.csv: one row per kept file, keyed by file name."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def rows(self) -> List[Dict[str, str]]:
        if not self.path.exists():
            return []
        with self.path.open(newline="", encoding="utf-8") as f:
            return [dict(r) for r in csv.DictReader(f)]

    def upsert(self, row: Dict[str, str]) -> None:
        rows = self.rows()
        for i, r in enumerate(rows):
            if r.get("file") == row["file"]:
                rows[i] = row
                self._rewrite(rows)
                return
        new = not self.path.exists() or self.path.stat().st_size == 0
        with self.path.open("a", newline="", encoding="utf-8") as f:
            w = self._writer(f)
            if new:
                w.writeheader()
            w.writerow(row)

    def remove(self, file: str) -> bool:
        rows = self.rows()
        keep = [r for r in rows if r.get("file") != file]
        if len(keep) == len(rows):
            return False
        self._rewrite(keep)
        return True

    @staticmethod
    def _writer(f: TextIO) -> csv.DictWriter:
        return csv.DictWriter(f, fieldnames=MANIFEST_FIELDS, extrasaction="ignore", restval="", lineterminator="\n")

    def _rewrite(self, rows: List[Dict[str, str]]) -> None:
        tmp = self.path.with_name(f".{self.path.name}.tmp")
        with tmp.open("w", newline="", encoding="utf-8") as f:
            w = self._writer(f)
            w.writeheader()
            w.writerows(rows)
        os.replace(tmp, self.path)


def manifest_row(file: str, speaker: str, take: str, index: int, stats: Stats, phrase: str, recorder: Recorder,
                 created: datetime) -> Dict[str, str]:
    return {
        "file": file,
        "speaker": speaker,
        "take": take,
        "index": str(index),
        "seconds": f"{stats.seconds:.3f}",
        "peak_dbfs": f"{stats.peak_dbfs:.1f}",
        "rms_dbfs": f"{stats.rms_dbfs:.1f}",
        "phrase": phrase,
        "backend": recorder.name,
        "device": recorder.device_label,
        "created_utc": created.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


# ----------------------------------------------------------------------------------------------------------------
# Session


class Console:
    """Terminal I/O and the clock, swappable in tests."""

    def __init__(self, input: Callable[[str], str] = input, out: Optional[TextIO] = None,
                 err: Optional[TextIO] = None, sleep: Callable[[float], None] = time.sleep,
                 now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> None:
        self.input = input
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr
        self.sleep = sleep
        self.now = now

    def say(self, text: str = "") -> None:
        print(text, file=self.out, flush=True)

    def fail(self, text: str) -> None:
        print(text, file=self.err, flush=True)

    def choose(self, prompt: str, allowed: Sequence[str]) -> str:
        """The user's answer, lower-cased, once it is one of [allowed]. End of input means "q"."""
        while True:
            self.out.write(prompt)
            self.out.flush()
            try:
                answer = self.input("").strip().lower()
            except EOFError:
                self.say()
                return "q"
            if answer in allowed:
                return answer
            self.say("  type " + ", ".join("Enter" if a == "" else a for a in allowed))


@dataclass
class Job:
    out_dir: Path
    speaker: str
    take: str
    count: int = 20
    seconds: float = 2.0
    phrase: str = DEFAULT_PHRASE
    cue_seconds: float = CUE_SECONDS


@dataclass
class Summary:
    out_dir: Path
    kept: int = 0
    rerecorded: int = 0
    deleted: int = 0

    def line(self) -> str:
        return f"kept {self.kept}, re-recorded {self.rerecorded}, deleted {self.deleted}; output: {self.out_dir}"


def record_clip(recorder: Recorder, dest: Path, seconds: float) -> Stats:
    """Records into a hidden temp file next to [dest], then finalize()s it into [dest]."""
    raw = dest.with_name(f".{dest.stem}.rec.wav")
    try:
        recorder.record(raw, seconds)
        return finalize(raw, dest, round(seconds * SAMPLE_RATE))
    finally:
        if raw.exists():
            raw.unlink()


def _record(console: Console, recorder: Recorder, dest: Path, seconds: float, cue_seconds: float,
            now_text: str) -> Optional[Stats]:
    """Starts recording cue_seconds + seconds at "ready...", says "now" after cue_seconds, then waits for the clip.

    The recorder runs on its own thread so the cue can be timed while it records. A RecordError comes back as None
    (reported); anything else from the thread (Ctrl-C included) is raised again here.
    """
    result: Dict[str, object] = {}

    def work() -> None:
        try:
            result["stats"] = record_clip(recorder, dest, cue_seconds + seconds)
        except BaseException as e:  # noqa: BLE001 - handed to the main thread
            result["error"] = e

    worker = threading.Thread(target=work, name="near-wake-record", daemon=True)
    console.say("  ready...")
    worker.start()
    try:
        console.sleep(cue_seconds)
        console.say(f"  now: {now_text}")
        worker.join()
    except KeyboardInterrupt:
        # The recorder got the same Ctrl-C and stops; let record_clip() remove its temp files before we exit.
        worker.join(STOP_WAIT_SECONDS)
        raise
    error = result.get("error")
    if isinstance(error, RecordError):
        console.say(f"  ! recording failed: {error}")
        return None
    if error is not None:
        raise error  # type: ignore[misc]
    stats = result["stats"]
    assert isinstance(stats, Stats)
    console.say(f"  peak {stats.peak_dbfs:.1f} dBFS, rms {stats.rms_dbfs:.1f} dBFS")
    for w in warnings_for(stats):
        console.say(f"  ! {w}")
    return stats


def run_takes(job: Job, recorder: Recorder, console: Console, summary: Optional[Summary] = None) -> Summary:
    """Records [job.count] takes of the phrase, asking after each one whether to keep, redo or delete it."""
    summary = summary if summary is not None else Summary(job.out_dir)
    job.out_dir.mkdir(parents=True, exist_ok=True)
    manifest = Manifest(job.out_dir / MANIFEST)
    condition = describe_condition(job.take)
    console.say(f"Speaker {job.speaker}, take {job.take}: {job.count} clips of {job.cue_seconds:g} s lead-in + "
                f"{job.seconds:g} s into {job.out_dir} ({recorder.name} {recorder.device_label})")
    start = next_index(job.out_dir, job.speaker, job.take)
    if start > 1:
        console.say(f"Resuming: {take_name(job.speaker, job.take, start - 1)} exists, "
                    f"next is {take_name(job.speaker, job.take, start)}")
    console.say(f'Recording starts at "ready...". Wait for "now" ({job.cue_seconds:g} s later), then say the phrase '
                "once. Ctrl-C stops.")
    n = 1
    while n <= job.count:
        index = next_index(job.out_dir, job.speaker, job.take)
        name = take_name(job.speaker, job.take, index)
        path = job.out_dir / name
        while True:
            console.say(f"\n({n}/{job.count}) {condition} -> {name}")
            stats = _record(console, recorder, path, job.seconds, job.cue_seconds, f'say "{job.phrase}"')
            if stats is None:
                if console.choose("  [Enter] try again  [q] quit > ", ("", "q")) == "q":
                    return summary
                continue
            manifest.upsert(manifest_row(name, job.speaker, job.take, index, stats, job.phrase, recorder,
                                         console.now()))
            choice = console.choose("  [Enter] keep  [r] redo  [d] delete  [q] keep and quit > ", ("", "r", "d", "q"))
            if choice == "r":
                summary.rerecorded += 1
                continue
            if choice == "d":
                path.unlink(missing_ok=True)
                manifest.remove(name)
                summary.deleted += 1
                console.say(f"  deleted {name}")
            else:
                summary.kept += 1
                console.say(f"  kept {name}")
            if choice == "q":
                return summary
            break
        n += 1
    return summary


def run_free(job: Job, minutes: float, recorder: Recorder, console: Console,
             summary: Optional[Summary] = None) -> Summary:
    """Records one long file of free speech or office background (negative or eval data)."""
    summary = summary if summary is not None else Summary(job.out_dir)
    job.out_dir.mkdir(parents=True, exist_ok=True)
    index = next_index(job.out_dir, job.speaker, job.take, free=True)
    name = free_name(job.speaker, job.take, index)
    path = job.out_dir / name
    seconds = minutes * 60
    console.say(f"Free recording: {minutes:g} min of free speech or background into {path} "
                f"({recorder.name} {recorder.device_label}). Ctrl-C aborts and keeps nothing.")
    stats = _record(console, recorder, path, seconds, job.cue_seconds,
                    f"talk freely, or let the room be ({minutes:g} min)")
    if stats is None:
        return summary
    Manifest(job.out_dir / MANIFEST).upsert(manifest_row(name, job.speaker, job.take, index, stats, "", recorder,
                                                         console.now()))
    summary.kept += 1
    console.say(f"  kept {name}")
    return summary


def list_devices(recorder: Recorder, console: Console) -> int:
    try:
        r = recorder.run_tool(recorder.list_command(), timeout=30)
    except RecordError as e:
        console.fail(str(e))
        return 1
    text = (r.stdout or "") + (r.stderr or "")
    if isinstance(recorder, FfmpegRecorder):
        # ffmpeg lists the devices, then fails to open input "": a non-zero exit is normal here.
        devices = parse_avfoundation_audio(text)
        if not devices:
            console.fail(text.strip() or "ffmpeg listed no AVFoundation audio devices")
            return 1
        console.say("AVFoundation audio inputs (pass --device <index>):")
        for i, name in devices:
            console.say(f"  {i}: {name}")
        return 0
    console.say(text.strip())
    if r.returncode == 0:
        console.say("Pass --device plughw:CARD=<card>,DEV=<device> (default: ALSA 'default').")
    return r.returncode


# ----------------------------------------------------------------------------------------------------------------
# CLI


def _name_type(what: str) -> Callable[[str], str]:
    def parse(value: str) -> str:
        try:
            return check_name(value, what)
        except ValueError as e:
            raise argparse.ArgumentTypeError(str(e)) from None
    return parse


def _positive(kind: Callable[[str], float], limit: Optional[float] = None) -> Callable[[str], float]:
    def parse(value: str) -> float:
        try:
            v = kind(value)
        except ValueError:
            raise argparse.ArgumentTypeError(f"not a number: {value!r}") from None
        if not v > 0 or (limit is not None and v > limit) or v != v:
            raise argparse.ArgumentTypeError(f"{value} must be above 0" + (f" and at most {limit:g}" if limit else ""))
        return v
    return parse


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python3 -m near_wake.record",
                                description='Record real "Hey Near" wake word takes (16 kHz mono s16 WAV).')
    p.add_argument("--list-devices", action="store_true", help="list input devices and exit")
    p.add_argument("--out", type=Path, help="output directory, outside any git work tree")
    p.add_argument("--speaker", type=_name_type("speaker"), help="speaker ID, a-z 0-9 -")
    p.add_argument("--take", type=_name_type("take label"), help="condition label, e.g. near, far, quiet, far-quiet")
    p.add_argument("--count", type=_positive(int), default=20, help="takes in this run (default 20)")
    p.add_argument("--seconds", type=_positive(float, MAX_TAKE_SECONDS), default=2.0,
                   help=f"length of each take after \"now\" (default 2.0); the clip also keeps the "
                        f"{CUE_SECONDS:g} s lead-in before it")
    p.add_argument("--backend", choices=BACKENDS, default="auto",
                   help="auto: ffmpeg on macOS, arecord on Linux")
    p.add_argument("--device", help="ffmpeg: AVFoundation audio index or name; arecord: ALSA PCM")
    p.add_argument("--phrase", default=DEFAULT_PHRASE, help=f'phrase to say (default "{DEFAULT_PHRASE}")')
    p.add_argument("--free", action="store_true", help="record one long file of free speech or background")
    p.add_argument("--minutes", type=_positive(float, MAX_FREE_MINUTES),
                   help="length of the --free recording after \"now\"")
    return p


def main(argv: Optional[List[str]] = None, *,
         recorder_factory: Callable[[str, Optional[str]], Recorder] = make_recorder,
         console: Optional[Console] = None, platform: str = sys.platform) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    console = console if console is not None else Console()
    try:
        backend = choose_backend(args.backend, platform)
    except ValueError as e:
        parser.error(str(e))
    recorder = recorder_factory(backend, args.device)
    if args.list_devices:
        return list_devices(recorder, console)

    missing = [flag for flag, v in (("--out", args.out), ("--speaker", args.speaker), ("--take", args.take))
               if v is None]
    if missing:
        parser.error("missing " + ", ".join(missing) + " (or use --list-devices)")
    if args.free and args.minutes is None:
        parser.error("--free needs --minutes")
    if args.minutes is not None and not args.free:
        parser.error("--minutes only goes with --free")
    if not args.free and not args.phrase.strip():
        parser.error("--phrase must not be empty")

    out_dir = args.out.expanduser().resolve()
    if inside_git_work_tree(out_dir):
        console.fail(f"Refusing {out_dir}: it is inside a git work tree, and recordings are private. "
                     "Pick a directory outside any repo, e.g. ~/near-wake-data/real")
        return 1
    if out_dir.exists() and not out_dir.is_dir():
        console.fail(f"{out_dir} is not a directory")
        return 1

    job = Job(out_dir, args.speaker, args.take, args.count, args.seconds, args.phrase.strip())
    summary = Summary(out_dir)
    code = 0
    try:
        if args.free:
            run_free(job, args.minutes, recorder, console, summary)
            code = 0 if summary.kept else 1
        else:
            run_takes(job, recorder, console, summary)
    except KeyboardInterrupt:
        console.say("\nInterrupted.")
        code = 130
    except OSError as e:
        console.fail(f"error: {e}")
        code = 1
    console.say(f"\nDone: {summary.line()}")
    return code


if __name__ == "__main__":
    sys.exit(main())
