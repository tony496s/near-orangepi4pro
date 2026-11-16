import os
import unittest

from near_voice.__main__ import DEFAULT_SOUNDS, parse_args
from near_voice.stt import DEFAULT_MODEL


class ParseArgsTest(unittest.TestCase):
    def test_defaults(self):
        a = parse_args([], env={})
        self.assertEqual((a.host, a.port, a.threads), ("127.0.0.1", 8781, 2))
        self.assertEqual(a.models, os.path.expanduser("~/near/models"))
        self.assertEqual(a.stt_model, DEFAULT_MODEL)
        self.assertIsNone(a.mic)
        self.assertIsNone(a.wav)
        self.assertEqual(a.sounds, DEFAULT_SOUNDS)
        self.assertTrue(os.path.isfile(os.path.join(DEFAULT_SOUNDS, "soft.wav")))

    def test_environment_then_flags(self):
        env = {"NEAR_VOICE_PORT": "9000", "NEAR_MODELS": "/m", "NEAR_MIC": "hw:9", "NEAR_SPEAKER": "hw:8"}
        a = parse_args([], env=env)
        self.assertEqual((a.port, a.models, a.mic, a.speaker), (9000, "/m", "hw:9", "hw:8"))
        self.assertEqual(parse_args(["--port", "7000"], env=env).port, 7000)


if __name__ == "__main__":
    unittest.main()
