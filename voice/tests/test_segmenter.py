import unittest

from near_voice.segmenter import NoSpeech, Segmenter, SegmenterConfig, Utterance

from .helpers import SILENCE, first_sample, frame

# With 32 ms frames and the default config: min_speech 8 frames, min_silence 19, max_speech 250, no_speech 125,
# lead 9, tail 9.
MIN_SPEECH, MIN_SILENCE, MAX_SPEECH, NO_SPEECH, LEAD, TAIL = 8, 19, 250, 125, 9, 9


class Feeder:
    """Feeds frames whose samples hold their position (1-based), so cut boundaries can be checked."""

    def __init__(self, seg: Segmenter) -> None:
        self.seg = seg
        self.n = 0

    def feed(self, speech: bool, count: int = 1, live: bool = True):
        result = None
        for _ in range(count):
            self.n += 1
            r = self.seg.feed(frame(self.n), speech, live=live)
            if r is not None:
                result = r
        return result


def positions(pcm: bytes):
    """First and last frame positions inside an utterance."""
    size = 1024
    return first_sample(pcm[:size]), first_sample(pcm[-size:])


class SegmenterTest(unittest.TestCase):
    def test_frame_counts_match_the_spec_timings(self):
        seg = Segmenter()
        self.assertEqual((seg._min_speech, seg._min_silence, seg._max_speech, seg._no_speech, seg._lead, seg._tail),
                         (MIN_SPEECH, MIN_SILENCE, MAX_SPEECH, NO_SPEECH, LEAD, TAIL))

    def test_pause_after_speech_ends_the_utterance_with_lead_and_tail(self):
        f = Feeder(Segmenter())
        self.assertIsNone(f.feed(False, 20))  # frames 1-20
        self.assertIsNone(f.feed(True, 30))  # frames 21-50
        self.assertTrue(f.seg.speaking)
        self.assertIsNone(f.feed(False, MIN_SILENCE - 1))
        result = f.feed(False)
        self.assertIsInstance(result, Utterance)
        self.assertFalse(result.forced)
        # speech 21..50, plus 9 frames before and 9 after
        self.assertEqual(positions(result.pcm), (21 - LEAD, 50 + TAIL))
        self.assertEqual(result.audio_ms, (30 + LEAD + TAIL) * 32)

    def test_short_gap_inside_speech_does_not_end_it(self):
        f = Feeder(Segmenter())
        f.feed(True, 20)
        self.assertIsNone(f.feed(False, MIN_SILENCE - 1))
        self.assertIsNone(f.feed(True, 10))
        result = f.feed(False, MIN_SILENCE)
        self.assertIsInstance(result, Utterance)
        self.assertEqual(positions(result.pcm), (1, 20 + (MIN_SILENCE - 1) + 10 + TAIL))

    def test_click_shorter_than_min_speech_is_ignored(self):
        f = Feeder(Segmenter())
        f.feed(True, MIN_SPEECH - 1)
        self.assertFalse(f.seg.speaking)
        result = f.feed(False, NO_SPEECH)
        self.assertIsInstance(result, NoSpeech)

    def test_speech_is_confirmed_at_min_speech_and_starts_at_its_first_frame(self):
        f = Feeder(Segmenter())
        f.feed(False, 15)
        f.feed(True, MIN_SPEECH - 1)
        self.assertFalse(f.seg.speaking)
        f.feed(True)
        self.assertTrue(f.seg.speaking)
        result = f.feed(False, MIN_SILENCE)
        self.assertEqual(positions(result.pcm)[0], 16 - LEAD)

    def test_long_speech_is_cut_at_max(self):
        f = Feeder(Segmenter())
        f.feed(False, 3)
        self.assertIsNone(f.feed(True, MAX_SPEECH - 1))
        result = f.feed(True)
        self.assertIsInstance(result, Utterance)
        self.assertTrue(result.forced)
        self.assertEqual(positions(result.pcm), (1, 3 + MAX_SPEECH))

    def test_no_speech_times_out_after_no_speech_live_frames(self):
        f = Feeder(Segmenter())
        self.assertIsNone(f.feed(False, NO_SPEECH - 1))
        result = f.feed(False)
        self.assertEqual(result, NoSpeech(peak=NO_SPEECH))  # frame values are positions: the loudest is the last

    def test_preroll_frames_do_not_count_toward_the_timeout(self):
        f = Feeder(Segmenter())
        f.feed(False, 16, live=False)
        self.assertIsNone(f.feed(False, NO_SPEECH - 1))
        self.assertEqual(f.seg.live_frames, NO_SPEECH - 1)
        self.assertIsInstance(f.feed(False), NoSpeech)

    def test_does_not_time_out_in_the_middle_of_a_word(self):
        f = Feeder(Segmenter())
        f.feed(False, NO_SPEECH - 3)
        self.assertIsNone(f.feed(True, MIN_SPEECH))  # crosses the timeout while a speech run is going on
        self.assertTrue(f.seg.speaking)
        self.assertIsInstance(f.feed(False, MIN_SILENCE), Utterance)

    def test_times_out_once_a_run_breaks_after_the_deadline(self):
        f = Feeder(Segmenter())
        f.feed(False, NO_SPEECH - 1)
        self.assertIsNone(f.feed(True, 2))
        self.assertIsInstance(f.feed(False), NoSpeech)

    def test_speech_that_started_in_the_preroll_is_kept(self):
        f = Feeder(Segmenter())
        f.feed(False, 4, live=False)
        f.feed(True, 12, live=False)  # the user spoke before touching the mic
        f.feed(True, 10)
        result = f.feed(False, MIN_SILENCE)
        self.assertEqual(positions(result.pcm)[0], 1)  # lead clipped at the start of the pre-roll

    def test_no_speech_peak_tells_a_dead_mic_from_a_quiet_room(self):
        seg = Segmenter()
        result = None
        for _ in range(NO_SPEECH):
            result = seg.feed(SILENCE, False) or result
        self.assertEqual(result, NoSpeech(peak=0))

    def test_result_is_returned_once(self):
        f = Feeder(Segmenter())
        f.feed(True, 10)
        self.assertIsNotNone(f.feed(False, MIN_SILENCE))
        self.assertTrue(f.seg.done)
        self.assertIsNone(f.feed(True, 300))

    def test_finish_cuts_now_when_speech_was_confirmed(self):
        f = Feeder(Segmenter())
        f.feed(False, 12)
        f.feed(True, 20)  # frames 13-32
        f.feed(False, 3)  # the user taps before the 0.6 s pause
        result = f.seg.finish()
        self.assertIsInstance(result, Utterance)
        self.assertFalse(result.forced)
        self.assertEqual(positions(result.pcm), (13 - LEAD, 35))
        self.assertIsNone(f.seg.finish(), "the result is given once")
        self.assertIsNone(f.feed(True))

    def test_finish_without_speech_is_no_speech(self):
        f = Feeder(Segmenter())
        f.feed(False, 10)
        f.feed(True, MIN_SPEECH - 1)  # too short to count
        self.assertEqual(f.seg.finish(), NoSpeech(peak=10 + MIN_SPEECH - 1))

    def test_custom_config(self):
        seg = Segmenter(SegmenterConfig(min_speech_s=0.064, min_silence_s=0.064, no_speech_s=0.32, lead_s=0, tail_s=0))
        f = Feeder(seg)
        f.feed(False, 2)
        f.feed(True, 2)
        result = f.feed(False, 2)
        self.assertEqual(positions(result.pcm), (3, 4))


if __name__ == "__main__":
    unittest.main()
