import asyncio
import os
import sys
import tempfile
import unittest

from near_voice.chime import Chimes, player_command


def runner(code: str):
    """A player stand-in that runs [code] instead of playing the file."""
    return lambda path, device, platform: [sys.executable, "-c", code]


class PlayerCommandTest(unittest.TestCase):
    def test_board_uses_aplay_on_the_hdmi_card_by_name(self):
        self.assertEqual(player_command("/s/soft.wav", platform="linux"),
                         ["aplay", "-q", "-D", "plughw:CARD=allwinnerhdmi,DEV=0", "/s/soft.wav"])
        self.assertIn("other", player_command("/s/soft.wav", "other", platform="linux"))

    def test_mac_uses_afplay(self):
        self.assertEqual(player_command("/s/soft.wav", platform="darwin"), ["afplay", "/s/soft.wav"])


class ChimesTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        for name in ("soft", "alert"):
            with open(os.path.join(self.tmp.name, f"{name}.wav"), "wb") as f:
                f.write(b"RIFF")

    def tearDown(self):
        self.tmp.cleanup()

    async def test_plays_a_known_chime(self):
        seen = []

        def player(path, device, platform):
            seen.append((path, device, platform))
            return [sys.executable, "-c", "pass"]

        chimes = Chimes(self.tmp.name, "dev", "linux", player=player)
        await chimes.play("soft")
        self.assertEqual(seen, [(os.path.join(self.tmp.name, "soft.wav"), "dev", "linux")])

    async def test_unknown_or_missing_chime_is_only_logged(self):
        os.remove(os.path.join(self.tmp.name, "alert.wav"))
        chimes = Chimes(self.tmp.name, player=runner("raise SystemExit(9)"))
        with self.assertLogs("near_voice.chime", "WARNING") as logs:
            await chimes.play("boom")
            await chimes.play("alert")
        self.assertIn("unknown name", logs.output[0])
        self.assertIn("missing", logs.output[1])

    async def test_player_failure_is_only_logged(self):
        chimes = Chimes(self.tmp.name, player=runner("import sys; sys.stderr.write('busy'); sys.exit(1)"))
        with self.assertLogs("near_voice.chime", "WARNING") as logs:
            await chimes.play("soft")
        self.assertIn("busy", logs.output[0])

    async def test_player_that_cannot_start_is_only_logged(self):
        chimes = Chimes(self.tmp.name, player=lambda *_: ["/nonexistent/player"])
        with self.assertLogs("near_voice.chime", "WARNING") as logs:
            await chimes.play("soft")
        self.assertIn("cannot run", logs.output[0])

    async def test_a_new_chime_stops_the_one_still_playing(self):
        chimes = Chimes(self.tmp.name, player=runner("import time; time.sleep(30)"))
        first = asyncio.ensure_future(chimes.play("alert"))
        while chimes._proc is None:
            await asyncio.sleep(0.01)
        slow = chimes._proc
        chimes.player = runner("pass")
        await chimes.play("soft")
        await asyncio.wait_for(first, 5)
        self.assertEqual(slow.returncode, -15)
        self.assertIsNone(chimes._proc)


if __name__ == "__main__":
    unittest.main()
