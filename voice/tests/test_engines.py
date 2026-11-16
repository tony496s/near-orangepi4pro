"""Real Silero VAD, Zipformer-vi and the keyword spotter. Runs only where the models are (the board):
NEAR_MODELS=~/near/models."""

import os
import tempfile
import unittest

from near_voice.audio import FRAME_BYTES, read_wav
from near_voice.stt import DEFAULT_MODEL

from .helpers import LOUD, SILENCE

MODELS = os.environ.get("NEAR_MODELS", "")
SAMPLE_WAV = os.path.join(MODELS, DEFAULT_MODEL, "test_wavs", "0.wav")

try:
    import sherpa_onnx  # noqa: F401

    HAVE_SHERPA = True
except ImportError:
    HAVE_SHERPA = False


@unittest.skipUnless(HAVE_SHERPA and os.path.isfile(os.path.join(MODELS, "silero_vad.onnx")),
                     "needs sherpa-onnx and NEAR_MODELS")
class EnginesTest(unittest.TestCase):
    def test_silero_vad(self):
        from near_voice.vad import SileroVad

        vad = SileroVad(os.path.join(MODELS, "silero_vad.onnx"))
        self.assertFalse(any(vad.is_speech(SILENCE) for _ in range(20)))
        vad.reset()
        with self.assertRaises(ValueError):  # a short window would abort the whole process inside sherpa-onnx
            vad.is_speech(LOUD[: FRAME_BYTES // 2])

    def test_vad_finds_speech_in_the_model_sample(self):
        from near_voice.vad import SileroVad

        pcm = read_wav(SAMPLE_WAV)
        vad = SileroVad(os.path.join(MODELS, "silero_vad.onnx"))
        flags = [vad.is_speech(pcm[i:i + FRAME_BYTES]) for i in range(0, len(pcm) - FRAME_BYTES + 1, FRAME_BYTES)]
        self.assertGreater(sum(flags), len(flags) // 3)

    def test_zipformer_transcribes_the_model_sample(self):
        from near_voice.stt import ZipformerStt

        stt = ZipformerStt(os.path.join(MODELS, DEFAULT_MODEL))
        stt.warm_up()
        self.assertEqual(stt.model, DEFAULT_MODEL)
        text = stt.transcribe(read_wav(SAMPLE_WAV))
        self.assertTrue(text)
        self.assertEqual(text, text.upper())  # Zipformer-vi gives upper case without punctuation
        self.assertEqual(stt.transcribe(bytes(FRAME_BYTES * 20)), "")



@unittest.skipUnless(HAVE_SHERPA and os.path.isdir(os.path.join(MODELS, "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20")),
                     "needs sherpa-onnx and the KWS model in NEAR_MODELS")
class KeywordSpotterTest(unittest.TestCase):
    def setUp(self):
        from near_voice import wake

        self.wake = wake
        self.model = os.path.join(MODELS, wake.DEFAULT_MODEL)

    def frames(self, pcm):
        return [pcm[i:i + FRAME_BYTES] for i in range(0, len(pcm) - FRAME_BYTES + 1, FRAME_BYTES)]

    def test_spots_light_up_in_the_model_sample(self):
        # The model's own sample says "... THE YELLOW LAMPS WOULD LIGHT UP HERE AND THERE ..." (test_wavs/en_trans.txt).
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("L AY1 T AH1 P @LIGHT_UP\n")
        self.addCleanup(os.unlink, f.name)
        kws = self.wake.SherpaKws(self.model, f.name, threshold=0.25, score=1.0)
        pcm = read_wav(os.path.join(self.model, "test_wavs", "en_0.wav")) + bytes(FRAME_BYTES * 20)
        hits = [k for k in (kws.accept(x) for x in self.frames(pcm)) if k]
        self.assertEqual(hits, ["LIGHT_UP"])

    def test_the_default_hey_near_keywords_load_and_silence_spots_nothing(self):
        kws = self.wake.SherpaKws(self.model)
        self.assertEqual(kws.model, self.wake.DEFAULT_MODEL)
        self.assertEqual([kws.accept(SILENCE) for _ in range(60)], [None] * 60)
        kws.reset()


if __name__ == "__main__":
    unittest.main()
