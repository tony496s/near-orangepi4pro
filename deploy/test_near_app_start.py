"""The boot wrapper, run without a board: every path and command is redirected through NEAR_* variables."""

import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "board" / "near-app-start.sh"


class StartScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.guard = self.tmp / "state" / "pending"
        self.card = self.tmp / "card0"
        self.card.touch()
        self.marker = self.tmp / "app-ran"
        vt = self.tmp / "vtconsole"
        for name, text in (("vtcon0", "(S) dummy device\n"), ("vtcon1", "(M) frame buffer device\n")):
            (vt / name).mkdir(parents=True)
            (vt / name / "name").write_text(text)
            (vt / name / "bind").write_text("1\n")
        self.vt = vt
        self.hpd_mask = self.tmp / "hpd_mask"
        self.hpd_mask.write_text("0x0\n")

    def env(self, app_cmd, **extra):
        env = dict(os.environ)
        env.update({
            "NEAR_GUARD": str(self.guard),
            "NEAR_VTCON_DIR": str(self.vt),
            "NEAR_CARD": str(self.card),
            "NEAR_CARD_WAIT_S": "1",
            "NEAR_MODPROBE": "",
            "NEAR_HPD_MASK_FILE": str(self.hpd_mask),
            "NEAR_HEALTHY_AFTER_S": "1",
            "NEAR_APP_CMD": app_cmd,
        })
        env.update(extra)
        return env

    def run_script(self, app_cmd, timeout=15, **extra):
        return subprocess.run(["sh", str(SCRIPT)], env=self.env(app_cmd, **extra), capture_output=True, text=True,
                              timeout=timeout)

    def test_healthy_run_unbinds_fbcon_and_clears_guard(self):
        r = self.run_script(f"echo ran > {self.marker}; sleep 2")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.marker.exists())
        self.assertEqual((self.vt / "vtcon1" / "bind").read_text().strip(), "0", "frame buffer console unbound")
        self.assertEqual((self.vt / "vtcon0" / "bind").read_text().strip(), "1", "dummy console left alone")
        self.assertIn("healthy after 1s", r.stdout)
        self.assertFalse(self.guard.exists())

    def test_guard_is_set_while_the_app_is_starting(self):
        p = subprocess.Popen(["sh", str(SCRIPT)], env=self.env("sleep 3", NEAR_HEALTHY_AFTER_S="2"),
                             stdout=subprocess.DEVNULL)
        try:
            time.sleep(0.7)
            self.assertTrue(self.guard.exists(), "guard must exist before the healthy timer fires")
        finally:
            p.wait(timeout=10)
        self.assertFalse(self.guard.exists())

    def test_early_crash_keeps_guard_and_returns_app_code(self):
        r = self.run_script("exit 3", NEAR_HEALTHY_AFTER_S="5")
        self.assertEqual(r.returncode, 3)
        self.assertIn("app exited (rc=3)", r.stdout)
        self.assertTrue(self.guard.exists(), "an early crash must leave the guard for the next boot")

    def test_leftover_guard_skips_the_ui_once(self):
        self.guard.parent.mkdir(parents=True)
        self.guard.touch()
        r = self.run_script(f"echo ran > {self.marker}")
        self.assertEqual(r.returncode, 0, "skipping is not a failure, so systemd does not restart it")
        self.assertIn("skipping the UI this boot", r.stdout)
        self.assertFalse(self.marker.exists(), "app must not start after a hung boot")
        self.assertEqual((self.vt / "vtcon1" / "bind").read_text().strip(), "1", "fbcon untouched when skipping")
        self.assertFalse(self.guard.exists(), "next boot tries again")

    def test_sigterm_stops_the_app_and_clears_guard(self):
        # The fake app kills its own sleep on TERM so no stray child holds the captured stdout open.
        app = f"trap 'echo term > {self.marker}; kill $s; exit 0' TERM; sleep 30 & s=$!; wait $s"
        p = subprocess.Popen(["sh", str(SCRIPT)], env=self.env(app, NEAR_HEALTHY_AFTER_S="20"),
                             stdout=subprocess.PIPE, text=True)
        time.sleep(1)
        p.send_signal(signal.SIGTERM)
        out, _ = p.communicate(timeout=10)
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("stopped on request", out)
        self.assertEqual(self.marker.read_text().strip(), "term", "TERM is forwarded to the app")
        self.assertFalse(self.guard.exists(), "a deliberate stop is not a hung start")

    def test_missing_card_waits_then_starts_anyway(self):
        self.card.unlink()
        r = self.run_script(f"echo ran > {self.marker}")
        self.assertIn("missing after 1s", r.stdout)
        self.assertTrue(self.marker.exists())

    def test_masks_hdmi_hotplug_before_starting(self):
        r = self.run_script(f"echo ran > {self.marker}")
        self.assertEqual(self.hpd_mask.read_text().strip(), "0x1100")
        self.assertIn("hdmi hpd mask set to 0x1100", r.stdout)
        self.assertTrue(self.marker.exists())

    def test_missing_hpd_mask_file_is_logged_and_not_fatal(self):
        r = self.run_script(f"echo ran > {self.marker}", NEAR_HPD_MASK_FILE=str(self.tmp / "nope"))
        self.assertIn("not writable, hdmi hotplug stays unmasked", r.stdout)
        self.assertTrue(self.marker.exists())

    def test_empty_hpd_mask_leaves_the_driver_alone(self):
        self.run_script(f"echo ran > {self.marker}", NEAR_HPD_MASK="")
        self.assertEqual(self.hpd_mask.read_text().strip(), "0x0")

    def test_skipped_boot_does_not_touch_hpd_mask(self):
        self.guard.parent.mkdir(parents=True)
        self.guard.touch()
        self.run_script("true")
        self.assertEqual(self.hpd_mask.read_text().strip(), "0x0")

    def test_app_runs_in_vietnam_time_by_default(self):
        r = self.run_script(f'echo "$TZ" > {self.marker}', TZ="")
        self.assertEqual(self.marker.read_text().strip(), "Asia/Ho_Chi_Minh")
        self.assertIn("app time zone Asia/Ho_Chi_Minh", r.stdout)

    def test_time_zone_can_be_overridden(self):
        self.run_script(f'echo "$TZ" > {self.marker}', NEAR_TZ="Asia/Tokyo")
        self.assertEqual(self.marker.read_text().strip(), "Asia/Tokyo")

    def test_empty_time_zone_leaves_the_system_one(self):
        r = self.run_script(f'echo "${{TZ-unset}}" > {self.marker}', NEAR_TZ="", TZ="Europe/Paris")
        self.assertEqual(self.marker.read_text().strip(), "Europe/Paris")
        self.assertNotIn("app time zone", r.stdout)

    def test_failing_modprobe_is_logged_and_not_fatal(self):
        r = self.run_script(f"echo ran > {self.marker}", NEAR_MODPROBE="false")
        self.assertIn("'false' failed", r.stdout)
        self.assertTrue(self.marker.exists())


class UnitFileTest(unittest.TestCase):
    def test_stop_signal_goes_to_the_wrapper_only(self):
        # Regression: with KillMode=control-group systemd also killed the wrapper's `rm`, leaving the guard behind.
        lines = [line.strip() for line in SCRIPT.with_name("near-app.service").read_text().splitlines()]
        self.assertIn("KillMode=mixed", lines)
        self.assertIn("ExecStart=/usr/local/sbin/near-app-start", lines)


if __name__ == "__main__":
    unittest.main()
