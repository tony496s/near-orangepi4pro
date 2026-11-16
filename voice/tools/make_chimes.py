"""Generates voice/sounds/{soft,alert}.wav: short sine chimes, 48 kHz mono 16-bit. Deterministic.

    python3 tools/make_chimes.py [out_dir]
"""

from __future__ import annotations

import math
import os
import struct
import sys
from typing import List, Sequence, Tuple

RATE = 48000
LEAD_S = 0.08  # HDMI sinks can swallow the first few ms after the device opens

# (start_s, freq_hz, length_s, gain)
Note = Tuple[float, float, float, float]

SOFT: Sequence[Note] = [(0.0, 659.25, 0.45, 0.22), (0.13, 987.77, 0.55, 0.18)]
ALERT: Sequence[Note] = [
    (0.0, 880.0, 0.22, 0.30), (0.16, 1174.66, 0.22, 0.30), (0.32, 1318.51, 0.40, 0.30),
    (0.80, 880.0, 0.22, 0.30), (0.96, 1174.66, 0.22, 0.30), (1.12, 1318.51, 0.50, 0.30),
]


def render(notes: Sequence[Note], rate: int = RATE) -> List[float]:
    end = max(start + length for start, _, length, _ in notes)
    out = [0.0] * int((LEAD_S + end + 0.05) * rate)
    for start, freq, length, gain in notes:
        first = int((LEAD_S + start) * rate)
        n = int(length * rate)
        attack = int(0.008 * rate)
        for i in range(n):
            env = min(1.0, i / attack) * math.exp(-5.0 * i / n) * (1 - i / n)
            # a little second harmonic makes it sound like a bell rather than a test tone
            v = math.sin(2 * math.pi * freq * i / rate) + 0.18 * math.sin(4 * math.pi * freq * i / rate)
            out[first + i] += gain * env * v
    return out


def to_wav(signal: Sequence[float], rate: int = RATE) -> bytes:
    pcm = b"".join(struct.pack("<h", max(-32767, min(32767, int(round(v * 32767))))) for v in signal)
    header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(pcm), b"WAVE", b"fmt ", 16, 1, 1, rate, rate * 2, 2,
                         16, b"data", len(pcm))
    return header + pcm


CHIMES = {"soft": SOFT, "alert": ALERT}


def main(argv: Sequence[str]) -> int:
    out_dir = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                                        "sounds")
    os.makedirs(out_dir, exist_ok=True)
    for name, notes in CHIMES.items():
        path = os.path.join(out_dir, f"{name}.wav")
        with open(path, "wb") as f:
            f.write(to_wav(render(notes)))
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
