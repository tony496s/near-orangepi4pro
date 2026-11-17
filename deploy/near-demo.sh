#!/bin/sh
# Builds the agent console demo from this tree and runs it on the board in demo mode. Runs on a Mac.
# Normally started by the `near-demo` launcher (deploy/near-demo-launcher.sh), which first forces its own clone to the
# frozen tag demo/agent-console-v1, so the demo comes back the same whatever happens on the other branches.
#
#   near-demo [ssh-host]                build, copy to ~/near/app-agents, switch the board to the demo, restart, check
#   near-demo --off [ssh-host]          back to the normal app (~/near/app), no build
#   near-demo --setup-board [ssh-host]  once per board: install the mode drop-in (asks for the board's sudo password)
#
# Board: the ssh-host argument or NEAR_BOARD / NEAR_SSH_OPTS from the environment; when none of them is set,
# ~/.config/near/board.env (NEAR_CONFIG=<file> for another one) may set both; otherwise plain `opi`.
#
# The demo mode is ~/near/mode.env on the board, which near-app reads through near-app.service.d/mode.conf
# (board/near-app-mode.conf), so switching needs no password: only `sudo -n systemctl restart near-app`.
# Paths and commands can be overridden through NEAR_* variables so test_near_demo.py runs it without a board.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)

usage() {
    echo "usage: near-demo [--off | --setup-board] [ssh-host]"
}

ACTION=up
case ${1:-} in
    --off) ACTION=off; shift ;;
    --setup-board) ACTION=setup; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
esac
if [ $# -gt 1 ]; then
    usage >&2
    exit 2
fi
HOST_ARG=${1:-}

# Anything given for this run replaces the config file as a whole: the office file's HostName option must not follow
# a board named on the command line.
CONFIG=${NEAR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/near/board.env}
if [ -n "$HOST_ARG" ] || [ -n "${NEAR_BOARD:-}" ] || [ -n "${NEAR_SSH_OPTS+set}" ]; then
    FROM="command line / environment"
elif [ -f "$CONFIG" ]; then
    . "$CONFIG"
    FROM=$CONFIG
else
    FROM="default"
fi
HOST=${HOST_ARG:-${NEAR_BOARD:-opi}}
OPTS=${NEAR_SSH_OPTS:-}
# The user's options come first: for ssh the first value of an option wins.
SSH="${NEAR_SSH:-ssh} $OPTS -o ConnectTimeout=10"
RSYNC=${NEAR_RSYNC:-rsync}
BUILD=${NEAR_BUILD:-$ROOT/deploy/build.sh}
BUNDLE=${NEAR_BUNDLE_DIR:-$ROOT/app/build/flutter-pi/aarch64-generic}
WAIT_S=${NEAR_DEMO_WAIT_S:-45}
AUTOSTART=${NEAR_AUTOSTART_FLAG:-/etc/near/autostart}
FLUTTER_VERSION=3.47.9  # the demo was built and checked on the board with it
DROPIN=/etc/systemd/system/near-app.service.d/mode.conf
LEGACY_DROPIN=/etc/systemd/system/near-app.service.d/agents.conf

REF=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)
case $REF in *[!A-Za-z0-9._/-]*) REF=unknown ;; esac  # it goes into a remote command line
case $WAIT_S in ''|*[!0-9]*) echo "NEAR_DEMO_WAIT_S must be a number of seconds" >&2; exit 2 ;; esac

say() { echo "near-demo: $*"; }

# The Flutter SDK for the build. flutterpi_tool runs on the first `dart` on PATH, which must be the one of the SDK it
# was activated against ("Invalid SDK hash" otherwise), and that SDK is the one that builds. A shell where another
# Flutter comes first (~/flutter) breaks the build, so this SDK's bin goes first. NEAR_FLUTTER_ROOT names one by hand.
flutter_root() {
    if [ -n "${NEAR_FLUTTER_ROOT:-}" ]; then
        echo "$NEAR_FLUTTER_ROOT"
        return
    fi
    cfg=${PUB_CACHE:-$HOME/.pub-cache}/global_packages/flutterpi_tool/.dart_tool/package_config.json
    [ -f "$cfg" ] || return 0
    sed -n 's|.*"rootUri": *"file://\(.*\)/packages/flutter_tools/*".*|\1|p' "$cfg" | head -n 1
}

# board <action>: runs the board-side script below (probe, up or off) over ssh.
board() {
    # shellcheck disable=SC2086  # $SSH is a command line on purpose, like in push.sh
    $SSH "$HOST" sh -s -- "$1" "$REF" "$WAIT_S" "$AUTOSTART" <<'BOARD'
main() {
    act=$1 ref=$2 wait_s=$3 flag=$4
    mode=near/mode.env
    cd || return 1
    case $act in
        probe) check_setup && prepare ;;
        up) prepare && switch_to_demo && restart ;;
        off) check_setup && rm -f "$mode" && restart ;;
    esac
}

check_setup() {
    case "$(systemctl show -p EnvironmentFiles near-app 2>/dev/null)" in
        *"$HOME/$mode"*) ;;
        *)
            echo "near-app on this board does not read ~/$mode yet; once per board run: near-demo --setup-board" >&2
            return 3 ;;
    esac
    if [ ! -e "$flag" ]; then
        echo "near-app does not start on this board ($flag missing): see 'Switch the display' in deploy/README.md" >&2
        return 4
    fi
    case "$(systemctl show -p Environment near-app 2>/dev/null)" in
        *NEAR_MODE=*) echo "warning: a drop-in still sets NEAR_MODE (the old agents.conf?), so --off cannot leave the" \
            "demo; near-demo --setup-board removes it" >&2 ;;
    esac
}

# The vsync-patched flutter-pi lives in each bundle folder and never comes with the build; the normal app has it.
prepare() {
    mkdir -p near/app-agents || return 5
    [ -x near/app-agents/flutter-pi ] && return 0
    if [ ! -x near/app/flutter-pi ]; then
        echo "no flutter-pi on the board (~/near/app/flutter-pi): set the board up first (deploy/README.md)" >&2
        return 5
    fi
    cp near/app/flutter-pi near/app-agents/flutter-pi.tmp && chmod 755 near/app-agents/flutter-pi.tmp \
        && mv near/app-agents/flutter-pi.tmp near/app-agents/flutter-pi || return 5
    echo "board: copied the vsync-patched flutter-pi from ~/near/app"
}

switch_to_demo() {
    printf '%s\n' "# Written by near-demo ($ref): near-app runs the agent console. near-demo --off deletes this file." \
        "NEAR_BUNDLE=$HOME/near/app-agents" "NEAR_MODE=agents" "NEAR_AGENTS_AUTOPLAY=0" > "$mode.tmp" \
        && mv "$mode.tmp" "$mode"
}

# Restarts near-app and waits for the boot wrapper's "healthy" line (the app still runs NEAR_HEALTHY_AFTER_S later).
restart() {
    tries=0
    while :; do
        tries=$((tries + 1))
        t0=$(date +%s)
        if ! sudo -n systemctl restart near-app < /dev/null; then
            echo "could not restart near-app without a password (sudo -n systemctl restart near-app)" >&2
            return 6
        fi
        waited=0
        while :; do
            log=$(journalctl -u near-app --since "@$t0" --no-pager -o cat < /dev/null 2>/dev/null)
            case $log in
                *"skipping the UI this boot"*) state=skipped ;;
                *"app exited (rc="*|*"Failed with result"*|*"Start request repeated too quickly"*) state=crashed ;;
                *"healthy after"*) state=healthy ;;
                *) state=starting ;;
            esac
            [ "$state" = starting ] || break
            if [ "$waited" -ge "$wait_s" ]; then
                state="not healthy after ${wait_s}s"
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
        # The wrapper skips one start after a start that never became healthy; the next one runs.
        if [ "$state" = skipped ] && [ "$tries" -lt 2 ]; then
            echo "board: the start before never became healthy, so this one was skipped; restarting once more"
            continue
        fi
        break
    done
    active=$(systemctl is-active near-app < /dev/null 2>/dev/null)
    if [ "$state" = healthy ] && [ "$active" = active ]; then
        echo "board: near-app is $active and healthy"
        return 0
    fi
    echo "near-app did not come up ($state, $active). Its journal since the restart:" >&2
    journalctl -u near-app --since "@$t0" --no-pager -n 40 < /dev/null >&2 2>/dev/null
    return 6
}

main "$@"
BOARD
}

# Runs `board <action>` and turns an ssh failure (255) into a hint about how the board is addressed.
on_board() {
    set +e
    board "$1"
    rc=$?
    set -e
    case $rc in
        0) ;;
        255)
            echo "near-demo: cannot reach $HOST over ssh (board from $FROM). Point it elsewhere with" \
                "NEAR_BOARD / NEAR_SSH_OPTS or $CONFIG" >&2
            exit 3 ;;
        *) exit "$rc" ;;
    esac
}

say "board $HOST${OPTS:+ ($OPTS)}, from $FROM"
case $ACTION in
    setup)
        # Two steps because sudo needs the terminal (ssh -t) to ask for the password, so stdin cannot carry the file.
        $RSYNC -a -e "$SSH" "$ROOT/deploy/board/near-app-mode.conf" "$HOST:near/near-app-mode.conf"
        $SSH -t "$HOST" "sudo install -D -m 644 near/near-app-mode.conf $DROPIN && sudo rm -f $LEGACY_DROPIN" \
            "&& sudo systemctl daemon-reload && rm -f near/near-app-mode.conf"
        say "board set up: near-app now reads ~/near/mode.env. Next: near-demo"
        ;;
    off)
        on_board off
        say "done: $HOST is back on the normal app (~/near/app)"
        ;;
    up)
        on_board probe
        SDK=$(flutter_root)
        if [ -n "$SDK" ] && [ ! -x "$SDK/bin/dart" ]; then
            echo "near-demo: no Flutter SDK at $SDK (NEAR_FLUTTER_ROOT, or the one flutterpi_tool was activated with)" >&2
            exit 1
        fi
        HAVE=$(sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' "$SDK/bin/cache/flutter.version.json" 2>/dev/null \
            || true)
        if [ "$HAVE" != "$FLUTTER_VERSION" ]; then
            say "WARNING: the demo was frozen with Flutter $FLUTTER_VERSION, this build uses ${HAVE:-an unknown one}" \
                "(${SDK:-flutter on PATH}); NEAR_FLUTTER_ROOT=<sdk> picks another"
        fi
        say "building $REF with Flutter ${HAVE:-?}"
        # A fresh clone has no .dart_tool and flutterpi_tool does not fetch packages; the tag's pubspec.lock is kept.
        (cd "$ROOT/app" && PATH=${SDK:+$SDK/bin:}$PATH flutter pub get --enforce-lockfile)
        PATH=${SDK:+$SDK/bin:}$PATH "$BUILD"
        if [ ! -f "$BUNDLE/app.so" ]; then
            echo "near-demo: no bundle in $BUNDLE after the build" >&2
            exit 1
        fi
        say "copying the bundle to $HOST:near/app-agents/"
        # The board keeps its vsync-patched flutter-pi; the bundle's stock one is not needed there.
        $RSYNC -a --delete --exclude flutter-pi --exclude flutter-pi.stock -e "$SSH" "$BUNDLE/" "$HOST:near/app-agents/"
        say "switching $HOST to the demo and restarting near-app (about 20 s until it counts as healthy)"
        on_board up
        say "done: the agent console ($REF) runs on $HOST, manual mode. Back to the normal app: near-demo --off"
        ;;
esac
