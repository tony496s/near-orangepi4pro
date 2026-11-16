"""What the synthetic clips say: "Hey Near" spellings that make TTS voices sound like the users, and near-misses.

The users are Vietnamese and say it roughly as "hây nia": open vowel, no final R, a little differently each time. A
Vietnamese recognizer heard their takes as "HAY NÀY", "THẦY NÀY", "THẦY NI À", "THẦY NÈ", "HAY ĐẤY À", "HAY ĐẤY Ạ":
those, and everyday phrases built from the same sounds, must not wake the device.

  POSITIVE_EN     spellings for English voices: the standard one and ones that push them towards "hây nia".
  POSITIVE_VI     Vietnamese-orthography approximations for Vietnamese voices.
  ADVERSARIAL_VI  Vietnamese near-misses and short sentences that contain them.
  ADVERSARIAL_EN  English near-misses.
"""

from __future__ import annotations

import random
import re
import unicodedata
from typing import Dict, List, Sequence

POSITIVE_EN: List[str] = [
    "hey near",
    "hey near!",
    "hey, near",
    "hey near.",
    "hey neer",
    "hey nia",
    "hey neeya",
    "hey nee-a",
    "hey neah",
    "hay near",
    "hay nia",
    "hey nee ah",
]

POSITIVE_VI: List[str] = [
    "hây nia",
    "hây nía",
    "hây ni a",
    "hê nia",
    "hây nhia",
    "hầy nia",
    "hấy nia",
    "hê nía",
    "hây nìa",
    "hế nia",
    "hây nia!",
    "hây, nia",
]

# What the Vietnamese recognizer heard when the users said "Hey Near" (phase 0, E4 session).
MISHEARINGS_VI: List[str] = [
    "hay này",
    "thầy này",
    "thầy ni à",
    "thầy nè",
    "hay đấy à",
    "hay đấy ạ",
]

ADVERSARIAL_VI: List[str] = MISHEARINGS_VI + [
    # Words and short phrases that share its sounds.
    "hay nè",
    "hay ghê",
    "hay nhỉ",
    "hay quá",
    "hay lắm",
    "hay là",
    "thầy ơi",
    "thấy nè",
    "này",
    "nè",
    "hay",
    "nia",
    "ê này",
    "hai nghìn",
    "bây giờ",
    "cây này",
    "tay này",
    "hây da",
    "hài ghê",
    "mai nhé",
    # Everyday sentences that contain them.
    "thầy này dạy hay lắm",
    "cái này hay đấy à",
    "phim này hay nè",
    "hay nhỉ, thầy nè",
    "bây giờ là mấy giờ rồi",
    "cây này cao ghê",
    "tay này đau quá",
    "hai nghìn đồng thôi",
    "này, hay đấy",
    "thầy ơi, cho em hỏi",
    "hay là mình đi ăn đi",
    "cô ấy nói hay ghê",
]

ADVERSARIAL_EN: List[str] = [
    "hey",
    "near",
    "hey there",
    "hey man",
    "hey Neil",
    "hey Nina",
    "hey new",
    "hey dear",
    "hey Mia",
    "hey you",
    "hey neighbor",
    "hi there",
    "here",
    "near me",
    "okay near",
    "is it near",
    "near the window",
    "hey, come here",
    "hey Siri",
]

TEXT_SETS: Dict[str, List[str]] = {
    "positive-en": POSITIVE_EN,
    "positive-vi": POSITIVE_VI,
    "adversarial-vi": ADVERSARIAL_VI,
    "adversarial-en": ADVERSARIAL_EN,
}

POSITIVE_SETS = ("positive-en", "positive-vi")


def text_set(name: str) -> List[str]:
    """The texts of the set called [name] (a TEXT_SETS key); KeyError naming the known sets otherwise."""
    try:
        return TEXT_SETS[name]
    except KeyError:
        raise KeyError(f"unknown text set {name!r}; known: {', '.join(TEXT_SETS)}") from None


def language(name: str) -> str:
    """"en" or "vi": the language of a TEXT_SETS name, i.e. which voices should read it."""
    text_set(name)
    return name.rsplit("-", 1)[1]


def normalize(text: str) -> str:
    """Lower case NFC words separated by single spaces, punctuation dropped; tones and other diacritics kept.

    "Hey, Near!" -> "hey near"; "hây nia" and "hay nè" stay different (in Vietnamese the marks change the word).
    """
    text = unicodedata.normalize("NFC", text).lower()
    text = re.sub(r"[^\w\s]|_", " ", text)
    return " ".join(text.split())


def contains_phrase(text: str, phrase: str) -> bool:
    """Whether the words of [phrase] appear in [text] as a run of whole words (after normalize)."""
    words, needle = normalize(text).split(), normalize(phrase).split()
    if not needle:
        return False
    return any(words[i:i + len(needle)] == needle for i in range(len(words) - len(needle) + 1))


def variants(texts: Sequence[str], n: int, seed: int = 0) -> List[str]:
    """[n] texts from [texts], every text used as evenly as possible, in an order fixed by [seed].

    The list is successive shuffles of [texts], so a larger [n] with the same seed only adds texts at the end:
    variants(t, 5, s) == variants(t, 10, s)[:5]. That keeps a resumed synthesis run saying the same things.
    """
    if n < 0:
        raise ValueError(f"n must be >= 0, got {n}")
    if not texts:
        if n:
            raise ValueError("no texts to choose from")
        return []
    rng = random.Random(f"near-wake-texts:{seed}")
    out: List[str] = []
    while len(out) < n:
        order = list(texts)
        rng.shuffle(order)
        out.extend(order)
    return out[:n]
