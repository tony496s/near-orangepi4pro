import unicodedata
import unittest
from collections import Counter

from near_wake import texts


class TextListsTest(unittest.TestCase):
    def test_every_list_is_non_empty_and_positives_are_a_plausible_size(self):
        for name, lines in texts.TEXT_SETS.items():
            with self.subTest(name=name):
                self.assertTrue(lines)
                self.assertTrue(all(isinstance(t, str) and t.strip() for t in lines))
        for lines in (texts.POSITIVE_EN, texts.POSITIVE_VI):
            self.assertGreaterEqual(len(lines), 8)
            self.assertLessEqual(len(lines), 15)

    def test_standard_spellings_are_there(self):
        self.assertIn("hey near", texts.POSITIVE_EN)
        self.assertIn("hây nia", texts.POSITIVE_VI)

    def test_no_duplicates_within_a_list(self):
        for name, lines in texts.TEXT_SETS.items():
            with self.subTest(name=name):
                # Punctuation variants ("hey near!") are deliberate: TTS reads them differently.
                self.assertEqual(len(set(lines)), len(lines))

    def test_recognizer_mishearings_are_adversarial(self):
        for heard in ["HAY NÀY", "THẦY NÀY", "THẦY NI À", "THẦY NÈ", "HAY ĐẤY À", "HAY ĐẤY Ạ"]:
            with self.subTest(heard=heard):
                self.assertIn(texts.normalize(heard), {texts.normalize(t) for t in texts.ADVERSARIAL_VI})

    def test_adversarials_include_sentences_that_contain_near_misses(self):
        self.assertIn("thầy này dạy hay lắm", texts.ADVERSARIAL_VI)
        self.assertIn("cái này hay đấy à", texts.ADVERSARIAL_VI)
        short = [t for t in texts.ADVERSARIAL_VI if len(texts.normalize(t).split()) <= 2]
        sentences = [t for t in texts.ADVERSARIAL_VI if len(texts.normalize(t).split()) >= 4]
        with_near_miss = [s for s in sentences if any(texts.contains_phrase(s, w) for w in short)]
        self.assertGreaterEqual(len(with_near_miss), 5, with_near_miss)

    def test_no_positive_appears_among_the_adversarials(self):
        positives = texts.POSITIVE_EN + texts.POSITIVE_VI
        adversarials = texts.ADVERSARIAL_EN + texts.ADVERSARIAL_VI
        for pos in positives:
            for adv in adversarials:
                with self.subTest(positive=pos, adversarial=adv):
                    self.assertNotEqual(texts.normalize(pos), texts.normalize(adv))
                    self.assertFalse(texts.contains_phrase(adv, pos))

    def test_set_names_and_languages(self):
        self.assertEqual(sorted(texts.TEXT_SETS), ["adversarial-en", "adversarial-vi", "positive-en", "positive-vi"])
        self.assertEqual(texts.language("positive-vi"), "vi")
        self.assertEqual(texts.language("adversarial-en"), "en")
        self.assertIs(texts.text_set("positive-en"), texts.POSITIVE_EN)
        with self.assertRaises(KeyError) as ctx:
            texts.text_set("positive-fr")
        self.assertIn("positive-en", str(ctx.exception))


class NormalizeTest(unittest.TestCase):
    def test_case_and_punctuation_go_diacritics_stay(self):
        self.assertEqual(texts.normalize("Hey, Near!"), "hey near")
        self.assertEqual(texts.normalize("  HÂY   nia. "), "hây nia")
        self.assertNotEqual(texts.normalize("hay nè"), texts.normalize("hây nia"))
        self.assertEqual(texts.normalize("hey nee-a"), "hey nee a")

    def test_decomposed_input_matches_composed(self):
        self.assertEqual(texts.normalize(unicodedata.normalize("NFD", "thầy này")), "thầy này")

    def test_contains_phrase_matches_whole_words_only(self):
        self.assertTrue(texts.contains_phrase("oh hey, near the door", "hey near"))
        self.assertFalse(texts.contains_phrase("hey nina", "hey nia"))
        self.assertFalse(texts.contains_phrase("hey", "hey near"))
        self.assertFalse(texts.contains_phrase("anything", "!!"), "an empty phrase never matches")


class VariantsTest(unittest.TestCase):
    LINES = ["a", "b", "c", "d", "e"]

    def test_same_seed_same_list(self):
        self.assertEqual(texts.variants(self.LINES, 17, seed=3), texts.variants(self.LINES, 17, seed=3))

    def test_other_seed_other_order(self):
        self.assertNotEqual(texts.variants(texts.POSITIVE_EN, 24, seed=1),
                            texts.variants(texts.POSITIVE_EN, 24, seed=2))

    def test_every_text_is_used_evenly(self):
        counts = Counter(texts.variants(self.LINES, 12, seed=0))
        self.assertEqual(set(counts), set(self.LINES))
        self.assertLessEqual(max(counts.values()) - min(counts.values()), 1)
        self.assertEqual(Counter(texts.variants(self.LINES, 10, seed=0)), Counter({t: 2 for t in self.LINES}))

    def test_a_longer_run_keeps_the_same_prefix(self):
        self.assertEqual(texts.variants(self.LINES, 7, seed=9), texts.variants(self.LINES, 20, seed=9)[:7])

    def test_edge_cases(self):
        self.assertEqual(texts.variants(self.LINES, 0, seed=0), [])
        self.assertEqual(texts.variants([], 0, seed=0), [])
        self.assertEqual(texts.variants(["only"], 3, seed=0), ["only"] * 3)
        with self.assertRaises(ValueError):
            texts.variants(self.LINES, -1)
        with self.assertRaises(ValueError):
            texts.variants([], 2)

    def test_input_is_not_modified(self):
        lines = list(self.LINES)
        texts.variants(lines, 10, seed=4)
        self.assertEqual(lines, self.LINES)


if __name__ == "__main__":
    unittest.main()
