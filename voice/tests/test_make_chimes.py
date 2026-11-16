import io
import os
import sys
import unittest
import wave
from array import array

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))

import make_chimes  # noqa: E402

SOUNDS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sounds")


class MakeChimesTest(unittest.TestCase):
    def test_generated_chimes_are_short_and_never_clip(self):
        for name, notes in make_chimes.CHIMES.items():
            with self.subTest(name=name):
                with wave.open(io.BytesIO(make_chimes.to_wav(make_chimes.render(notes)))) as w:
                    self.assertEqual((w.getframerate(), w.getnchannels(), w.getsampwidth()), (48000, 1, 2))
                    self.assertLess(w.getnframes() / w.getframerate(), 2.0)
                    samples = array("h", w.readframes(w.getnframes()))
                self.assertLess(max(abs(s) for s in samples), 32767 * 0.5)
                lead = int(make_chimes.LEAD_S * 48000)
                self.assertEqual(max(abs(s) for s in samples[:lead]), 0)

    def test_committed_sounds_match_the_generator(self):
        for name, notes in make_chimes.CHIMES.items():
            with self.subTest(name=name):
                with open(os.path.join(SOUNDS, f"{name}.wav"), "rb") as f:
                    self.assertEqual(f.read(), make_chimes.to_wav(make_chimes.render(notes)))


if __name__ == "__main__":
    unittest.main()
