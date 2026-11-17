"""near-demo and its launcher, run without a board or GitHub.

The fake ssh runs the board side for real in a scratch home, with fake sudo, systemctl and journalctl on its PATH, so
the tests see the files near-demo leaves on the "board". The launcher clones a local git repo instead of GitHub.
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

DEPLOY = Path(__file__).parent
SCRIPT = DEPLOY / "near-demo.sh"
LAUNCHER = DEPLOY / "near-demo-launcher.sh"
TAG = "demo/agent-console-v1"
HEALTHY = "near-app: app started (pid 42)\nnear-app: healthy after 20s\n"


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return path


def clean_env(**extra):
    """The test process environment without anything that would point near-demo at a real board."""
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("NEAR_") or k.startswith("GIT_") or k == "XDG_CONFIG_HOME")}
    env.update({k: str(v) for k, v in extra.items()})
    return env


class NearDemoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Shared by all tests: macOS scans every new executable on its first run (about 0.5 s each). Per-test state
        # comes in through $FAKE (service state and call log) and $FAKE_HOME (the board user's home).
        cls.shared = Path(tempfile.mkdtemp())
        cls.addClassCleanup(shutil.rmtree, cls.shared, ignore_errors=True)
        cls.bin = cls.shared / "bin"
        log = 'echo "$(basename "$0") $*" >> "$FAKE/calls"'
        cls.ssh = executable(cls.bin / "ssh", "\n".join([
            log,
            'while [ $# -gt 0 ]; do case $1 in -o) shift 2 ;; -t) shift ;; *) break ;; esac; done',
            'host=$1; shift',
            '[ "$host" = down ] && { echo "ssh: connect to host down: No route to host" >&2; exit 255; }',
            'cd "$FAKE_HOME" && HOME=$FAKE_HOME exec sh -c "$*"',
        ]))
        cls.rsync = executable(cls.bin / "rsync", log)
        cls.build = executable(cls.bin / "build", "\n".join([
            log, 'echo "dart=$(command -v dart)" >> "$FAKE/calls"', '[ -z "${FAKE_BUILD_FAILS:-}" ] || exit 1']))
        executable(cls.bin / "flutter", "\n".join([
            'echo "flutter $* in $(pwd)" >> "$FAKE/calls"', '[ -z "${FAKE_PUB_GET_FAILS:-}" ] || exit 1']))
        executable(cls.bin / "sudo", "\n".join([
            log, '[ "$1" = -n ] && shift', 'case $1 in systemctl) exec "$@" ;; esac']))
        executable(cls.bin / "journalctl", log + '\ncat "$FAKE/journal" 2>/dev/null; true')
        executable(cls.bin / "systemctl", "\n".join([
            log,
            "case $1 in",
            '  show) case $3 in EnvironmentFiles) [ -e "$FAKE/dropin" ] && '
            'echo "EnvironmentFiles=$HOME/near/mode.env (ignore_errors=yes)" ;;',
            '        Environment) cat "$FAKE/unit_env" 2>/dev/null ;; esac; true ;;',
            '  is-active) cat "$FAKE/active" 2>/dev/null || echo active ;;',
            '  restart) n=$(( $(cat "$FAKE/restarts" 2>/dev/null || echo 0) + 1 )); echo $n > "$FAKE/restarts"',
            '           [ -f "$FAKE/journal.$n" ] && cp "$FAKE/journal.$n" "$FAKE/journal"; true ;;',
            "esac",
        ]))

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.own_bin = self.tmp / "bin"  # per-test replacements, ahead of the shared fakes
        self.fake = self.tmp / "fake"  # state of the fake board services
        self.fake.mkdir()
        self.calls = self.fake / "calls"
        self.home = self.tmp / "board"  # the board user's home
        executable(self.home / "near/app/flutter-pi", "echo patched")
        (self.home / "near/app/app.so").write_text("normal app")
        (self.fake / "dropin").touch()  # near-app reads ~/near/mode.env
        self.autostart = self.fake / "autostart"
        self.autostart.touch()
        self.journal(HEALTHY)
        self.bundle = self.tmp / "bundle"
        self.bundle.mkdir()
        (self.bundle / "app.so").write_text("demo")

    def journal(self, text, after_restart=None):
        """What `journalctl -u near-app --since <restart>` shows (from restart number `after_restart` on)."""
        name = "journal" if after_restart is None else f"journal.{after_restart}"
        (self.fake / name).write_text(text)

    def run_demo(self, *args, cwd=None, **env):
        base = {
            "PATH": f"{self.own_bin}:{self.bin}:{os.environ['PATH']}", "FAKE": self.fake, "FAKE_HOME": self.home,
            "NEAR_SSH": self.ssh, "NEAR_RSYNC": self.rsync, "NEAR_BUILD": self.build,
            "NEAR_BUNDLE_DIR": self.bundle, "NEAR_CONFIG": self.tmp / "no-config", "NEAR_DEMO_WAIT_S": 2,
            "NEAR_AUTOSTART_FLAG": self.autostart, "PUB_CACHE": self.tmp / "pub-cache",
        }
        base.update(env)
        return subprocess.run(["sh", str(SCRIPT), *args], env=clean_env(**base), capture_output=True, text=True,
                              timeout=60, cwd=cwd or self.tmp)

    def log(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def called(self, prefix):
        return [c for c in self.log() if c.startswith(prefix)]

    def mode_env(self):
        return (self.home / "near/mode.env").read_text()

    def restarts(self):
        return self.called("sudo -n systemctl restart near-app")

    # --- the demo goes up

    def test_builds_copies_switches_to_the_demo_and_waits_until_healthy(self):
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.log()
        order = [c.split()[0] for c in calls if c.split()[0] in ("build", "rsync")]
        self.assertEqual(order, ["build", "rsync"])
        self.assertLess(calls.index(self.called("ssh")[0]), calls.index("build "), "board checked before the build")
        sync = self.called("rsync")[0]
        self.assertIn("-a --delete --exclude flutter-pi --exclude flutter-pi.stock", sync)
        self.assertTrue(sync.endswith(f"{self.bundle}/ opi:near/app-agents/"), sync)
        lines = [line for line in self.mode_env().splitlines() if not line.startswith("#")]
        self.assertEqual(lines, [f"NEAR_BUNDLE={self.home}/near/app-agents", "NEAR_MODE=agents",
                                 "NEAR_AGENTS_AUTOPLAY=0"])
        self.assertIn("Written by near-demo", self.mode_env())
        self.assertFalse((self.home / "near/mode.env.tmp").exists())
        self.assertEqual(len(self.restarts()), 1, "restarted once, without a password")
        self.assertIn("journalctl -u near-app --since @", "\n".join(self.log()))
        self.assertIn("near-app is active and healthy", r.stdout)
        self.assertIn("manual mode", r.stdout)

    def test_copies_the_patched_flutter_pi_into_the_demo_bundle_the_first_time(self):
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        copied = self.home / "near/app-agents/flutter-pi"
        self.assertEqual(copied.read_text(), (self.home / "near/app/flutter-pi").read_text())
        self.assertTrue(os.access(copied, os.X_OK))
        self.assertIn("copied the vsync-patched flutter-pi", r.stdout)

    def test_keeps_a_flutter_pi_already_in_the_demo_bundle(self):
        executable(self.home / "near/app-agents/flutter-pi", "echo demo-own")
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("demo-own", (self.home / "near/app-agents/flutter-pi").read_text())
        self.assertNotIn("copied", r.stdout)

    def test_no_flutter_pi_on_the_board_stops_before_the_build(self):
        (self.home / "near/app/flutter-pi").unlink()
        r = self.run_demo()
        self.assertEqual(r.returncode, 5)
        self.assertIn("no flutter-pi on the board", r.stderr)
        self.assertEqual(self.called("build") + self.called("rsync") + self.restarts(), [])

    def test_replaces_whatever_mode_was_there(self):
        (self.home / "near/mode.env").write_text("NEAR_MODE=other\nNEAR_AGENTS_AUTOPLAY=1\n")
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("other", self.mode_env())
        self.assertIn("NEAR_AGENTS_AUTOPLAY=0", self.mode_env(), "the frozen demo is the manual one")

    # --- the board is not ready

    def test_a_board_without_the_mode_drop_in_is_told_to_run_setup(self):
        (self.fake / "dropin").unlink()
        r = self.run_demo()
        self.assertEqual(r.returncode, 3)
        self.assertIn("near-demo --setup-board", r.stderr)
        self.assertEqual(self.called("build") + self.called("rsync") + self.restarts(), [])
        self.assertFalse((self.home / "near/mode.env").exists())

    def test_a_board_where_near_app_does_not_start_is_reported(self):
        self.autostart.unlink()
        r = self.run_demo()
        self.assertEqual(r.returncode, 4)
        self.assertIn("Switch the display", r.stderr)
        self.assertEqual(self.called("build"), [])

    def test_warns_when_an_old_drop_in_still_sets_the_mode(self):
        (self.fake / "unit_env").write_text("Environment=NEAR_BUNDLE=/x NEAR_MODE=agents\n")
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("agents.conf", r.stderr)

    def test_unreachable_board_fails_fast_with_a_hint(self):
        r = self.run_demo("down")
        self.assertEqual(r.returncode, 3)
        self.assertIn("cannot reach down", r.stderr)
        self.assertIn("NEAR_SSH_OPTS", r.stderr)
        self.assertEqual(self.called("build"), [])

    # --- the build

    def test_a_failed_build_leaves_the_board_alone(self):
        r = self.run_demo(FAKE_BUILD_FAILS=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.called("rsync") + self.restarts(), [])
        self.assertFalse((self.home / "near/mode.env").exists())

    def test_fetches_the_locked_packages_in_the_app_before_building(self):
        # Regression: flutterpi_tool does not run pub get, so a fresh clone failed on a missing package_config.json.
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.log()
        pub_get = f"flutter pub get --enforce-lockfile in {DEPLOY.parent.resolve()}/app"
        self.assertIn(pub_get, calls)
        self.assertLess(calls.index(pub_get), calls.index("build "))

    def test_failed_package_fetch_stops_before_the_build(self):
        r = self.run_demo(FAKE_PUB_GET_FAILS=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.called("build") + self.called("rsync") + self.restarts(), [])

    def test_a_build_without_a_bundle_is_an_error(self):
        (self.bundle / "app.so").unlink()
        r = self.run_demo()
        self.assertEqual(r.returncode, 1)
        self.assertIn("no bundle", r.stderr)
        self.assertEqual(self.called("rsync"), [])

    def flutter_sdk(self, name, version):
        root = self.tmp / name
        executable(root / "bin/dart", "true")  # never run: the fake build only looks it up
        executable(root / "bin/flutter", f'echo "{name}/flutter $*" >> "$FAKE/calls"')
        (root / "bin/cache").mkdir(parents=True)
        (root / "bin/cache/flutter.version.json").write_text(f'{{\n  "frameworkVersion": "{version}",\n}}\n')
        return root

    def activate_flutterpi_tool(self, sdk):
        cfg = self.tmp / "pub-cache/global_packages/flutterpi_tool/.dart_tool/package_config.json"
        cfg.parent.mkdir(parents=True)
        cfg.write_text('{\n  "packages": [\n    {\n      "name": "flutter_tools",\n'
                       f'      "rootUri": "file://{sdk}/packages/flutter_tools",\n    }}\n  ]\n}}\n')

    def test_builds_with_the_flutter_sdk_flutterpi_tool_belongs_to(self):
        # Regression: from a shell with another Flutter first on PATH, flutterpi_tool died with "Invalid SDK hash".
        sdk = self.flutter_sdk("brew-flutter", "3.47.9")
        self.activate_flutterpi_tool(sdk)
        other = self.flutter_sdk("home-flutter", "3.47.2")
        r = self.run_demo(PATH=f"{other}/bin:{self.own_bin}:{self.bin}:{os.environ['PATH']}")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"dart={sdk}/bin/dart", self.log())
        self.assertIn("brew-flutter/flutter pub get --enforce-lockfile", self.log())
        self.assertIn("with Flutter 3.47.9", r.stdout)
        self.assertNotIn("WARNING", r.stdout)

    def test_another_flutter_version_builds_with_a_warning(self):
        self.activate_flutterpi_tool(self.flutter_sdk("brew-flutter", "3.48.0"))
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("WARNING: the demo was frozen with Flutter 3.47.9, this build uses 3.48.0", r.stdout)

    def test_flutter_sdk_by_hand(self):
        self.activate_flutterpi_tool(self.flutter_sdk("brew-flutter", "3.48.0"))
        mine = self.flutter_sdk("mine", "3.47.9")
        r = self.run_demo(NEAR_FLUTTER_ROOT=mine)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"dart={mine}/bin/dart", self.log())
        self.assertNotIn("WARNING", r.stdout)

    def test_a_missing_flutter_sdk_stops_before_the_build(self):
        self.activate_flutterpi_tool(self.tmp / "gone")
        r = self.run_demo()
        self.assertEqual(r.returncode, 1)
        self.assertIn(f"no Flutter SDK at {self.tmp}/gone", r.stderr)
        self.assertEqual(self.called("build") + self.called("rsync"), [])

    def test_without_flutterpi_tool_in_the_pub_cache_the_path_is_left_alone(self):
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("WARNING: the demo was frozen with Flutter 3.47.9, this build uses an unknown one", r.stdout)

    # --- checking the restart

    def test_a_crash_after_the_restart_fails_and_shows_the_journal(self):
        self.journal("near-app: app started (pid 42)\nnear-app: app exited (rc=139)\n")
        r = self.run_demo()
        self.assertEqual(r.returncode, 6)
        self.assertIn("did not come up (crashed", r.stderr)
        self.assertIn("app exited (rc=139)", r.stderr)

    def test_no_healthy_line_in_time_fails(self):
        self.journal("near-app: app started (pid 42)\n")
        r = self.run_demo(NEAR_DEMO_WAIT_S=1)
        self.assertEqual(r.returncode, 6)
        self.assertIn("not healthy after 1s", r.stderr)

    def test_healthy_but_not_active_fails(self):
        (self.fake / "active").write_text("failed\n")
        r = self.run_demo()
        self.assertEqual(r.returncode, 6)
        self.assertIn("healthy, failed", r.stderr)

    def test_a_start_skipped_by_the_boot_guard_is_retried_once(self):
        self.journal("near-app: previous start never became healthy (hang or early crash); skipping the UI this boot\n",
                     after_restart=1)
        self.journal(HEALTHY, after_restart=2)
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.restarts()), 2)
        self.assertIn("restarting once more", r.stdout)

    def test_a_start_skipped_twice_is_not_retried_forever(self):
        self.journal("near-app: skipping the UI this boot\n")
        r = self.run_demo()
        self.assertEqual(r.returncode, 6)
        self.assertEqual(len(self.restarts()), 2)

    def test_restart_needing_a_password_fails_clearly(self):
        executable(self.own_bin / "sudo",
                   'echo "sudo $*" >> "$FAKE/calls"; echo "sudo: a password is required" >&2; exit 1')
        r = self.run_demo()
        self.assertEqual(r.returncode, 6)
        self.assertIn("without a password", r.stderr)

    # --- back to the normal app

    def test_off_deletes_the_mode_file_and_restarts_without_a_build(self):
        (self.home / "near/mode.env").write_text("NEAR_MODE=agents\n")
        r = self.run_demo("--off")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((self.home / "near/mode.env").exists())
        self.assertEqual(len(self.restarts()), 1)
        self.assertEqual(self.called("build") + self.called("rsync"), [])
        self.assertIn("back on the normal app", r.stdout)

    def test_off_on_a_board_without_the_drop_in_changes_nothing(self):
        (self.fake / "dropin").unlink()
        (self.home / "near/mode.env").write_text("NEAR_MODE=agents\n")
        r = self.run_demo("--off")
        self.assertEqual(r.returncode, 3)
        self.assertTrue((self.home / "near/mode.env").exists())
        self.assertEqual(self.restarts(), [])

    # --- one-time board setup

    def test_setup_board_installs_the_drop_in_with_an_interactive_sudo(self):
        r = self.run_demo("--setup-board")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        sync = self.called("rsync")[0]
        self.assertTrue(sync.endswith(f"{DEPLOY}/board/near-app-mode.conf opi:near/near-app-mode.conf"), sync)
        ssh = self.called("ssh")[0]
        self.assertIn(" -t opi ", ssh, "a terminal, so sudo can ask for the password")
        self.assertEqual(self.called("sudo"), [
            "sudo install -D -m 644 near/near-app-mode.conf /etc/systemd/system/near-app.service.d/mode.conf",
            "sudo rm -f /etc/systemd/system/near-app.service.d/agents.conf",
            "sudo systemctl daemon-reload",
        ])
        self.assertEqual(self.called("build"), [])

    # --- where the board is

    def ssh_line(self):
        return self.called("ssh")[0]

    def config(self, text):
        path = self.tmp / "board.env"
        path.write_text(text)
        return path

    def test_default_board_is_opi_with_a_connect_timeout(self):
        r = self.run_demo()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.ssh_line().startswith("ssh -o ConnectTimeout=10 opi sh -s -- probe "), self.ssh_line())
        self.assertIn("from default", r.stdout)

    def test_config_file_sets_the_board_and_its_ssh_options(self):
        cfg = self.config('NEAR_BOARD=lab\nNEAR_SSH_OPTS="-o HostName=lab.example.invalid -o HostKeyAlias=lab-key"\n')
        r = self.run_demo(NEAR_CONFIG=cfg)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        opts = "-o HostName=lab.example.invalid -o HostKeyAlias=lab-key -o ConnectTimeout=10"
        self.assertTrue(self.ssh_line().startswith(f"ssh {opts} lab sh -s"), self.ssh_line())
        self.assertIn(f"-e {self.ssh} {opts} {self.bundle}/ lab:near/app-agents/", self.called("rsync")[0])
        self.assertIn(f"from {cfg}", r.stdout)

    def test_default_config_file_lives_in_the_user_config_folder(self):
        cfg_home = self.tmp / "xdg"
        (cfg_home / "near").mkdir(parents=True)
        (cfg_home / "near/board.env").write_text("NEAR_BOARD=fromfile\n")
        r = self.run_demo(NEAR_CONFIG="", XDG_CONFIG_HOME=cfg_home)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(" fromfile sh -s", self.ssh_line())

    def test_board_from_the_environment_replaces_the_whole_config_file(self):
        cfg = self.config('NEAR_BOARD=lab\nNEAR_SSH_OPTS="-o HostName=lab.example.invalid"\n')
        r = self.run_demo(NEAR_CONFIG=cfg, NEAR_BOARD="home")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.ssh_line().startswith("ssh -o ConnectTimeout=10 home sh -s"), self.ssh_line())

    def test_empty_ssh_options_from_the_environment_ignore_the_config_file(self):
        cfg = self.config('NEAR_BOARD=lab\nNEAR_SSH_OPTS="-o HostName=lab.example.invalid"\n')
        r = self.run_demo(NEAR_CONFIG=cfg, NEAR_SSH_OPTS="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.ssh_line().startswith("ssh -o ConnectTimeout=10 opi sh -s"), self.ssh_line())

    def test_host_argument_wins(self):
        cfg = self.config("NEAR_BOARD=lab\n")
        r = self.run_demo("other", NEAR_CONFIG=cfg, NEAR_BOARD="home", NEAR_SSH_OPTS="-o Port=2222")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.ssh_line().startswith("ssh -o Port=2222 -o ConnectTimeout=10 other sh -s"))

    # --- usage

    def test_unknown_option_or_extra_arguments_are_usage_errors(self):
        for args in (["--nope"], ["a", "b"]):
            with self.subTest(args=args):
                r = self.run_demo(*args)
                self.assertEqual(r.returncode, 2)
                self.assertIn("usage", r.stderr)
        self.assertEqual(self.log(), [])

    def test_help(self):
        r = self.run_demo("--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("--setup-board", r.stdout)
        self.assertEqual(self.log(), [])


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=clean_env(**GIT_ENV), check=True, capture_output=True,
                          text=True).stdout.strip()


GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@example.invalid", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}


class LauncherTest(unittest.TestCase):
    """The launcher against a local "GitHub": the tag has a stub deploy/near-demo.sh that reports where it ran."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        git(self.origin, "init", "-q", "-b", "main")
        executable(self.origin / "deploy/near-demo.sh",
                   'cd "$(dirname "$0")/.."; echo "demo $(git rev-parse HEAD) args:$*"\n'
                   'ls app/lib/agents 2>/dev/null || echo no agents')
        (self.origin / "app/lib/agents").mkdir(parents=True)
        (self.origin / "app/lib/agents/console.dart").write_text("v1\n")
        (self.origin / ".gitignore").write_text("build/\n")
        git(self.origin, "add", ".")
        git(self.origin, "commit", "-q", "-m", "demo")
        git(self.origin, "tag", "-a", TAG, "-m", "frozen demo")
        self.demo_sha = git(self.origin, "rev-parse", "HEAD")
        # The product moves on and drops the demo, after the tag.
        git(self.origin, "rm", "-q", "-r", "app/lib/agents")
        git(self.origin, "commit", "-q", "-m", "product without the demo")
        self.cache = self.tmp / "cache"
        self.src = self.cache / "src"
        self.elsewhere = self.tmp / "somewhere"
        self.elsewhere.mkdir()

    def launch(self, *args, repo=None, **env):
        base = {"NEAR_DEMO_REPO": repo or f"file://{self.origin}", "NEAR_DEMO_CACHE": self.cache, **GIT_ENV}
        base.update(env)
        return subprocess.run(["sh", str(LAUNCHER), *args], env=clean_env(**base), cwd=self.elsewhere,
                              capture_output=True, text=True, timeout=60)

    def test_runs_the_tags_script_from_its_own_clone_with_the_arguments(self):
        r = self.launch("--off", "lab")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"demo {self.demo_sha} args:--off lab", r.stdout)
        self.assertIn("console.dart", r.stdout, "the demo code is there although main deleted it")
        self.assertEqual(git(self.src, "rev-parse", "HEAD"), self.demo_sha)
        self.assertEqual(git(self.src, "status", "--porcelain"), "")

    def test_fetches_only_the_tag(self):
        self.launch()
        self.assertEqual(git(self.src, "for-each-ref", "--format=%(refname)"), f"refs/tags/{TAG}")

    def test_every_run_forces_the_clone_back_to_the_tag(self):
        self.launch()
        (self.src / "app/lib/agents/console.dart").write_text("edited\n")
        (self.src / "stray.txt").write_text("x")
        (self.src / "build").mkdir()
        (self.src / "build/cache").write_text("stale")
        r = self.launch()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.src / "app/lib/agents/console.dart").read_text(), "v1\n")
        self.assertFalse((self.src / "stray.txt").exists())
        self.assertFalse((self.src / "build").exists(), "old build output goes too: the build starts clean")

    def test_follows_a_tag_that_was_moved(self):
        self.launch()
        git(self.origin, "checkout", "-q", self.demo_sha)
        (self.origin / "app/lib/agents/console.dart").write_text("v1 fixed\n")
        git(self.origin, "commit", "-q", "-am", "fix")
        git(self.origin, "tag", "-f", "-a", TAG, "-m", "moved")
        r = self.launch()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.src / "app/lib/agents/console.dart").read_text(), "v1 fixed\n")

    def test_another_tag(self):
        git(self.origin, "tag", "-a", "demo/other", "-m", "other")
        r = self.launch(NEAR_DEMO_TAG="demo/other")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("no agents", r.stdout, "demo/other is the commit without the demo")

    def test_offline_uses_the_tag_fetched_before(self):
        self.launch()
        r = self.launch(repo=f"file://{self.tmp}/gone")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("using the copy fetched before", r.stderr)
        self.assertIn(f"demo {self.demo_sha}", r.stdout)

    def test_offline_without_a_copy_fails_without_running_anything(self):
        r = self.launch(repo=f"file://{self.tmp}/gone")
        self.assertEqual(r.returncode, 1)
        self.assertIn(f"cannot get {TAG}", r.stderr)
        self.assertNotIn("demo ", r.stdout)

    def test_missing_tag_fails(self):
        r = self.launch(NEAR_DEMO_TAG="demo/none")
        self.assertEqual(r.returncode, 1)
        self.assertIn("cannot get demo/none", r.stderr)


if __name__ == "__main__":
    unittest.main()
