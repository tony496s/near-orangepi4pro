import os
import unittest

from near_voice import wake
from near_voice.__main__ import DEFAULT_SOUNDS, parse_args
from near_voice.harness import DEFAULT_API, DEFAULT_AUTH_FILE
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

    def test_cloud_stt_and_wake_are_off_unless_asked(self):
        a = parse_args([], env={})
        self.assertEqual((a.stt, a.stt_lang, a.cloud_timeout, a.stt_en), ("local", "vi", 3.0, "off"))
        self.assertEqual((a.harness_api, a.harness_auth), (DEFAULT_API, DEFAULT_AUTH_FILE))
        self.assertEqual(DEFAULT_API, "https://harness-api.autonomous.ai")
        self.assertEqual((a.wake, a.wake_model, a.wake_keywords), ("off", wake.DEFAULT_MODEL, wake.DEFAULT_KEYWORDS))
        self.assertEqual((a.wake_threshold, a.wake_score), (0.15, 2.0))

    def test_cloud_stt_and_wake_from_the_environment(self):
        env = {"NEAR_STT": "cloud", "NEAR_CLOUD_TIMEOUT": "2.5", "NEAR_HARNESS_AUTH": "/s/a.json",
               "NEAR_HARNESS_API": "http://127.0.0.1:3000", "NEAR_WAKE": "kws", "NEAR_WAKE_THRESHOLD": "0.1",
               "NEAR_WAKE_SCORE": "1.5", "NEAR_WAKE_KEYWORDS": "/k.txt"}
        a = parse_args([], env=env)
        self.assertEqual((a.stt, a.cloud_timeout, a.harness_auth, a.harness_api),
                         ("cloud", 2.5, "/s/a.json", "http://127.0.0.1:3000"))
        self.assertEqual((a.wake, a.wake_threshold, a.wake_score, a.wake_keywords), ("kws", 0.1, 1.5, "/k.txt"))
        self.assertEqual(parse_args(["--stt", "local", "--wake", "off"], env=env).stt, "local")

    def test_english_through_harness_from_the_environment(self):
        self.assertEqual(parse_args([], env={"NEAR_STT_EN": "harness"}).stt_en, "harness")
        self.assertEqual(parse_args(["--stt-en", "off"], env={"NEAR_STT_EN": "harness"}).stt_en, "off")

    def test_unknown_engines_are_refused(self):
        for argv in (["--stt", "whisper"], ["--stt-en", "parakeet"]):
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                parse_args(argv, env={})


if __name__ == "__main__":
    unittest.main()
