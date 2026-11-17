"""Deploy scripts and unit files, run without a board: ssh, rsync, curl and python are replaced by fakes."""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

DEPLOY = Path(__file__).parent
BOARD = DEPLOY / "board"
STT = "sherpa-onnx-zipformer-vi-30M-int8-2026-02-09"
STT_FILES = ["encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt"]
KWS = "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20"
KWS_FILES = ["encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx", "decoder-epoch-13-avg-2-chunk-16-left-64.onnx",
             "joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx", "tokens.txt"]


def make_model(base, name, files):
    d = base / name
    d.mkdir(parents=True)
    for f in files:
        (d / f).write_text(f)
    return d


def unit(name):
    """systemd unit as {(section, key): [values]}."""
    out, section = {}, None
    for line in (BOARD / name).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line.strip("[]")
            continue
        key, _, value = line.partition("=")
        out.setdefault((section, key), []).append(value)
    return out


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def fake(self, name, body):
        """An executable shell script at tmp/bin/<name>."""
        path = self.tmp / "bin" / name
        path.parent.mkdir(exist_ok=True)
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
        return path

    def run_sh(self, script, *args, **env):
        e = dict(os.environ)
        e.update({k: str(v) for k, v in env.items()})
        return subprocess.run(["sh", str(script), *args], env=e, capture_output=True, text=True, timeout=30)


class UnitFilesTest(unittest.TestCase):
    def test_app_unit_replaces_the_phase0_ui_and_pulls_in_voice(self):
        u = unit("near-app.service")
        self.assertEqual(u[("Service", "ExecStart")], ["/usr/local/sbin/near-app-start"])
        self.assertEqual(u[("Service", "KillMode")], ["mixed"])
        self.assertIn("phase0-flutter.service", u[("Unit", "Conflicts")][0].split())
        self.assertIn("lightdm.service", u[("Unit", "Conflicts")][0].split())
        self.assertEqual(u[("Unit", "Wants")], ["near-voice.service"])
        self.assertEqual(u[("Unit", "ConditionPathExists")], ["/etc/near/autostart"])

    def test_app_starts_only_after_the_conflicting_uis_have_stopped(self):
        # Regression: without an ordering, `systemctl start near-app` stopped phase0-flutter in parallel and the new
        # flutter-pi came up while the old one still held DRM master ("drmdev is paused", black screen).
        u = unit("near-app.service")
        after = u[("Unit", "After")][0].split()
        for other in u[("Unit", "Conflicts")][0].split():
            self.assertIn(other, after)

    def test_voice_unit_runs_as_the_user_on_the_a76_cores(self):
        u = unit("near-voice.service")
        self.assertEqual(u[("Service", "User")], ["orangepi"])
        self.assertIn("audio", u[("Service", "SupplementaryGroups")][0].split())
        exec_start = u[("Service", "ExecStart")][0].split()
        self.assertEqual(exec_start[:3], ["/usr/bin/taskset", "-c", "6,7"])
        self.assertEqual(exec_start[3:], ["/home/orangepi/near/venv/bin/python", "-m", "near_voice"])
        self.assertEqual(u[("Service", "WorkingDirectory")], ["/home/orangepi/near/voice"])
        self.assertEqual(u[("Service", "Environment")], [
            "NEAR_MODELS=/home/orangepi/near/models", "NEAR_STT=local", "NEAR_STT_EN=harness",
            "NEAR_HARNESS_AUTH=/home/orangepi/near/secrets/harness-auth.json", "NEAR_WAKE=kws"])
        self.assertEqual(u[("Unit", "ConditionPathExists")], ["/etc/near/autostart"])

    def test_wrapper_default_bundle_matches_where_push_puts_it(self):
        text = (BOARD / "near-app-start.sh").read_text()
        self.assertIn("BUNDLE=${NEAR_BUNDLE:-/home/$RUN_AS/near/app}", text)
        self.assertIn('"$HOST:near/app/"', (DEPLOY / "push.sh").read_text())

    def test_mode_drop_in_reads_an_optional_file_in_the_users_home(self):
        u = unit("near-app-mode.conf")
        # "-": without the file near-app runs exactly as the unit says.
        self.assertEqual(u, {("Service", "EnvironmentFile"): ["-/home/orangepi/near/mode.env"]})
        # near-demo writes it as the same user, relative to that home.
        self.assertIn("mode=near/mode.env", (DEPLOY / "near-demo.sh").read_text())

    def test_scripts_parse(self):
        for script in [*DEPLOY.glob("*.sh"), *BOARD.glob("*.sh")]:
            with self.subTest(script=script.name):
                r = subprocess.run(["sh", "-n", str(script)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertTrue(os.access(script, os.X_OK), "scripts are executable")


class InstallTest(Scratch):
    def test_installs_wrapper_and_units_into_the_root(self):
        r = self.run_sh(BOARD / "install.sh", NEAR_ROOT=self.tmp)
        self.assertEqual(r.returncode, 0, r.stderr)
        wrapper = self.tmp / "usr/local/sbin/near-app-start"
        self.assertEqual(wrapper.read_text(), (BOARD / "near-app-start.sh").read_text())
        self.assertEqual(stat.S_IMODE(wrapper.stat().st_mode), 0o755)
        for name in ("near-app.service", "near-voice.service"):
            installed = self.tmp / "etc/systemd/system" / name
            self.assertEqual(installed.read_text(), (BOARD / name).read_text())
            self.assertEqual(stat.S_IMODE(installed.stat().st_mode), 0o644)
        dropin = self.tmp / "etc/systemd/system/near-app.service.d/mode.conf"
        self.assertEqual(dropin.read_text(), (BOARD / "near-app-mode.conf").read_text())
        self.assertEqual(stat.S_IMODE(dropin.stat().st_mode), 0o644)
        self.assertTrue((self.tmp / "etc/near").is_dir())
        self.assertFalse((self.tmp / "etc/near/autostart").exists(), "installing must not switch what boots")
        self.assertEqual(list((self.tmp / "etc/systemd/system").rglob("*.tmp")), [])
        self.assertFalse((self.tmp / "home").exists(), "installing must not write the mode file")

    def test_refuses_to_touch_the_system_without_root(self):
        if os.geteuid() == 0:
            self.skipTest("running as root")
        r = self.run_sh(BOARD / "install.sh")
        self.assertEqual(r.returncode, 1)
        self.assertIn("sudo", r.stderr)


class PushTest(Scratch):
    def setUp(self):
        super().setUp()
        self.log = self.tmp / "calls"
        self.ssh = self.fake("ssh", f'echo "ssh $*" >> {self.log}')
        self.rsync = self.fake("rsync", f'echo "rsync $*" >> {self.log}')
        self.bundle = self.tmp / "bundle"
        self.bundle.mkdir()
        (self.bundle / "app.so").write_text("x")

    def push(self, *args, **env):
        base = {"NEAR_SSH": self.ssh, "NEAR_RSYNC": self.rsync, "NEAR_BUNDLE_DIR": self.bundle}
        base.update(env)
        return self.run_sh(DEPLOY / "push.sh", *args, **base)

    def test_copies_bundle_voice_and_board_scripts_but_keeps_the_patched_flutter_pi(self):
        r = self.push("board", NEAR_SSH_OPTS="-o HostKeyAlias=x")
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(calls[0], "ssh -o HostKeyAlias=x board mkdir -p near/app near/voice near/deploy")
        bundle_sync = calls[1]
        self.assertIn("--delete --exclude flutter-pi --exclude flutter-pi.stock", bundle_sync)
        self.assertTrue(bundle_sync.endswith(f"{self.bundle}/ board:near/app/"))
        self.assertTrue(calls[2].endswith(f"{self.bundle}/flutter-pi board:near/app/flutter-pi.stock"))
        self.assertTrue(calls[3].endswith("voice/ board:near/voice/"))
        self.assertTrue(calls[4].endswith("deploy/board/ board:near/deploy/"))
        self.assertTrue(all(f"-e {self.ssh} -o HostKeyAlias=x" in c for c in calls[1:]))

    def test_needs_a_host(self):
        r = self.push(NEAR_BOARD="")
        self.assertEqual(r.returncode, 2)
        self.assertIn("usage", r.stderr)
        self.assertFalse(self.log.exists())

    def test_host_from_the_environment(self):
        r = self.push(NEAR_BOARD="fromenv")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(" fromenv mkdir", self.log.read_text())

    def test_needs_a_built_bundle(self):
        (self.bundle / "app.so").unlink()
        r = self.push("board")
        self.assertEqual(r.returncode, 1)
        self.assertIn("deploy/build.sh", r.stderr)
        self.assertFalse(self.log.exists())


class FetchModelsTest(Scratch):
    def setUp(self):
        super().setUp()
        self.models = self.tmp / "models"
        self.seed = self.tmp / "seed"
        self.curl_log = self.tmp / "curl"
        self.kws_seed = self.tmp / "kws-seed"

    def make_stt(self, base):
        return make_model(base, STT, STT_FILES)

    def fetch(self, curl=None):
        env = {"NEAR_MODELS": self.models, "NEAR_MODELS_SEED": self.seed, "NEAR_MODELS_URL": "https://example.invalid",
               "NEAR_KWS_SEED": self.kws_seed, "NEAR_KWS_URL": "https://kws.example.invalid"}
        env["NEAR_CURL"] = curl or self.fake("curl", f'echo "$*" >> {self.curl_log}; exit 22')
        return self.run_sh(BOARD / "fetch_models.sh", **env)

    def test_copies_from_the_phase0_download(self):
        self.seed.mkdir()
        (self.seed / "silero_vad.onnx").write_text("vad")
        self.make_stt(self.seed)
        r = self.fetch()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.models / "silero_vad.onnx").read_text(), "vad")
        self.assertEqual((self.models / STT / "tokens.txt").read_text(), "tokens.txt")
        self.assertFalse((self.models / ".extract").exists())

    def test_copies_the_wake_word_model_from_the_phase0_download(self):
        self.seed.mkdir()
        (self.seed / "silero_vad.onnx").write_text("vad")
        self.make_stt(self.seed)
        make_model(self.kws_seed, KWS, KWS_FILES + ["en.phone"])
        r = self.fetch()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"copied {KWS}", r.stdout)
        self.assertEqual(sorted(p.name for p in (self.models / KWS).iterdir()), sorted(KWS_FILES + ["en.phone"]))
        self.assertFalse(self.curl_log.exists(), "nothing downloaded")
        self.assertNotIn("WARNING", r.stderr)

    def test_a_missing_wake_word_model_is_only_a_warning(self):
        self.seed.mkdir()
        (self.seed / "silero_vad.onnx").write_text("vad")
        self.make_stt(self.seed)
        r = self.fetch()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("without the wake word", r.stderr)
        self.assertIn(f"https://kws.example.invalid/{KWS}.tar.bz2", self.curl_log.read_text())
        self.assertEqual(sorted(p.name for p in self.models.iterdir()), sorted(["silero_vad.onnx", STT]))

    def test_skips_models_already_there(self):
        self.models.mkdir()
        (self.models / "silero_vad.onnx").write_text("mine")
        self.make_stt(self.models)
        r = self.fetch()
        self.assertEqual(r.returncode, 0)
        self.assertIn(f"have {STT}", r.stdout)
        self.assertEqual((self.models / "silero_vad.onnx").read_text(), "mine")

    def test_downloads_when_there_is_no_seed(self):
        # A fake curl that serves the VAD file and a real tar.bz2 of the STT model.
        src = self.tmp / "release"
        self.make_stt(src)
        subprocess.run(["tar", "cjf", str(self.tmp / "stt.tar.bz2"), "-C", str(src), STT], check=True)
        curl = self.fake("curl", "\n".join([
            f'echo "$*" >> {self.curl_log}',
            'out=$2; url=$3',  # called as: curl -o <out> <url>
            'case "$url" in',
            '  *.tar.bz2) cp ' + str(self.tmp / "stt.tar.bz2") + ' "$out" ;;',
            '  *) echo vad > "$out" ;;',
            'esac',
        ]))
        r = self.fetch(curl)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.models / "silero_vad.onnx").read_text().strip(), "vad")
        self.assertEqual(sorted(p.name for p in (self.models / STT).iterdir()), sorted(STT_FILES))
        urls = self.curl_log.read_text()
        self.assertIn("https://example.invalid/silero_vad.onnx", urls)
        self.assertIn(f"https://example.invalid/{STT}.tar.bz2", urls)
        self.assertEqual(sorted(p.name for p in self.models.iterdir()), sorted(["silero_vad.onnx", STT]))

    def test_failed_download_leaves_nothing_half_done_and_fails(self):
        r = self.fetch()
        self.assertEqual(r.returncode, 1)
        self.assertIn("MISSING", r.stderr)
        self.assertEqual(list(self.models.iterdir()), [])

    def test_incomplete_model_directory_is_replaced(self):
        broken = self.models / STT
        broken.mkdir(parents=True)
        (broken / "tokens.txt").write_text("partial")
        (self.models / "silero_vad.onnx").write_text("vad")
        self.seed.mkdir()
        self.make_stt(self.seed)
        r = self.fetch()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.models / STT / "encoder.int8.onnx").read_text(), "encoder.int8.onnx")


class SetupTest(Scratch):
    def setUp(self):
        super().setUp()
        self.near = self.tmp / "near"
        (self.near / "app").mkdir(parents=True)
        (self.near / "models").mkdir()
        (self.near / "models" / "silero_vad.onnx").write_text("vad")
        make_model(self.near / "models", STT, STT_FILES)
        make_model(self.near / "models", KWS, KWS_FILES)

    def setup_sh(self, **env):
        # NEAR_CURL: nothing is downloaded for real, whatever the test leaves out.
        base = {"NEAR_HOME": self.near, "NEAR_PYTHON": "", "NEAR_FLUTTER_PI": self.tmp / "nope",
                "NEAR_CURL": self.fake("curl", "exit 22")}
        base.update(env)
        return self.run_sh(BOARD / "setup.sh", **base)

    def test_installs_the_patched_flutter_pi(self):
        patched = self.fake("flutter-pi", "echo patched")
        (self.near / "app" / "flutter-pi.stock").write_text("stock")
        r = self.setup_sh(NEAR_FLUTTER_PI=patched)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        installed = self.near / "app" / "flutter-pi"
        self.assertEqual(installed.read_text(), patched.read_text())
        self.assertTrue(os.access(installed, os.X_OK))
        self.assertIn("vsync-patched", r.stdout)

    def test_falls_back_to_the_stock_flutter_pi_with_a_warning(self):
        stock = self.near / "app" / "flutter-pi.stock"
        stock.write_text("stock")
        stock.chmod(0o755)
        r = self.setup_sh()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.near / "app" / "flutter-pi").read_text(), "stock")
        self.assertIn("WARNING", r.stdout)

    def test_makes_an_owner_only_folder_for_the_harness_sign_in(self):
        stock = self.near / "app" / "flutter-pi.stock"
        stock.write_text("stock")
        stock.chmod(0o755)
        r = self.setup_sh()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(stat.S_IMODE((self.near / "secrets").stat().st_mode), 0o700)
        self.assertIn("near/secrets/harness-auth.json", (BOARD / "near-voice.service").read_text())

    def test_fails_without_any_flutter_pi(self):
        r = self.setup_sh()
        self.assertEqual(r.returncode, 1)
        self.assertIn("push the bundle first", r.stderr)

    def test_creates_the_venv_and_installs_requirements(self):
        log = self.tmp / "py"
        venv_py = self.near / "venv" / "bin" / "python"
        # Fake python3: "-m venv DIR" creates DIR/bin/python (itself a logger); anything else is logged.
        python = self.fake("python3", "\n".join([
            f'echo "python3 $*" >> {log}',
            'if [ "$1 $2" = "-m venv" ]; then mkdir -p "$3/bin"; '
            f'printf \'#!/bin/sh\\necho "venv $*" >> {log}\\n\' > "$3/bin/python"; chmod +x "$3/bin/python"; fi',
        ]))
        stock = self.near / "app" / "flutter-pi.stock"
        stock.write_text("stock")
        stock.chmod(0o755)
        r = self.setup_sh(NEAR_PYTHON=python)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(venv_py.exists())
        calls = log.read_text().splitlines()
        self.assertEqual(calls[0], f"python3 -m venv {self.near}/venv")
        self.assertEqual(calls[1], f"venv -m pip install -q -r {self.near}/voice/requirements.txt")
        # a second run reuses the venv
        self.setup_sh(NEAR_PYTHON=python)
        self.assertEqual(log.read_text().splitlines()[2:], [calls[1]])


if __name__ == "__main__":
    unittest.main()
