#!/bin/sh
# Starts the Near app on the bar display (installed as /usr/local/sbin/near-app-start, run as root by near-app.service).
# Taken from the Phase 0 boot wrapper, which was tested on this board.
#
# Safety guard: a "start pending" file is written before anything that could hang the kernel (fbcon unbind, GPU
# module load, first frame) and removed once the app has run for NEAR_HEALTHY_AFTER_S seconds or is stopped on
# purpose. If a boot finds the file still there, the previous start hung or crashed early, so this boot skips the UI
# (ssh stays reachable) and clears the file; the boot after that tries again.
#
# Every path and command can be overridden through NEAR_* variables so test_near_app_start.py runs it without a board.
set -u

GUARD=${NEAR_GUARD:-/var/lib/near/app-start-pending}
# Short on purpose: a power cut inside this window also counts as "never healthy" and costs one UI-less boot.
# The risky steps (module load, first KMS commit) finish within ~5 s of start even on a cold boot.
HEALTHY_AFTER_S=${NEAR_HEALTHY_AFTER_S:-20}
RUN_AS=${NEAR_RUN_AS:-orangepi}
BUNDLE=${NEAR_BUNDLE:-/home/$RUN_AS/near/app}
VTCON_DIR=${NEAR_VTCON_DIR:-/sys/class/vtconsole}
CARD=${NEAR_CARD:-/dev/dri/card0}
CARD_WAIT_S=${NEAR_CARD_WAIT_S:-10}
MODPROBE=${NEAR_MODPROBE-modprobe pvrsrvkm}
HPD_MASK_FILE=${NEAR_HPD_MASK_FILE:-/sys/devices/virtual/hdmi/hdmi/attr/hpd_mask}
# 0x100 masks the hotplug notify, 0x1000 the hotplug detect. Without it, a monitor power blip makes the sunxi HDMI
# driver switch its output off for good: every later KMS commit fails with EINVAL until a reboot.
HPD_MASK=${NEAR_HPD_MASK-0x1100}
# The board's system clock is UTC; the strip shows local time. Empty keeps the system zone.
APP_TZ=${NEAR_TZ-Asia/Ho_Chi_Minh}

log() { echo "near-app: $*"; }

if [ -e "$GUARD" ]; then
    rm -f "$GUARD"
    sync
    log "previous start never became healthy (hang or early crash); skipping the UI this boot, next boot tries again"
    exit 0
fi
mkdir -p "$(dirname "$GUARD")"
: > "$GUARD"
sync

# fbcon must be gone before any DRM master comes and goes: falling back to the text console hangs this BSP.
for vt in "$VTCON_DIR"/vtcon*; do
    [ -f "$vt/name" ] || continue
    if grep -q "frame buffer" "$vt/name"; then
        echo 0 > "$vt/bind" && log "unbound $(basename "$vt") ($(cat "$vt/name"))"
    fi
done

if [ -n "$HPD_MASK" ]; then
    if [ -w "$HPD_MASK_FILE" ]; then
        echo "$HPD_MASK" > "$HPD_MASK_FILE" && log "hdmi hpd mask set to $HPD_MASK"
    else
        log "$HPD_MASK_FILE not writable, hdmi hotplug stays unmasked"
    fi
fi

if [ -n "$MODPROBE" ]; then
    $MODPROBE || log "'$MODPROBE' failed (rc=$?), starting anyway"
fi

waited=0
while [ ! -e "$CARD" ] && [ "$waited" -lt "$CARD_WAIT_S" ]; do
    sleep 1
    waited=$((waited + 1))
done
[ -e "$CARD" ] || log "$CARD missing after ${CARD_WAIT_S}s, starting anyway"

if [ -n "$APP_TZ" ]; then
    export TZ="$APP_TZ"
    log "app time zone $APP_TZ"
fi

if [ -n "${NEAR_APP_CMD:-}" ]; then
    sh -c "$NEAR_APP_CMD" &
else
    # flutter-pi is the vsync-patched build (phase0/flutter-pi-vsync), copied into the bundle by setup.sh.
    setpriv --reuid="$RUN_AS" --regid="$RUN_AS" --init-groups \
        env HOME="/home/$RUN_AS" LD_LIBRARY_PATH="/usr/local/lib:$BUNDLE" \
        "$BUNDLE/flutter-pi" --release -r 270 "$BUNDLE" &
fi
app=$!
log "app started (pid $app)"

stopping=0
on_stop() {
    stopping=1
    rm -f "$GUARD"
    sync
    kill -TERM "$app" 2>/dev/null
}
trap on_stop TERM INT

# Healthy timer. It takes its sleep down with it when told to stop, so nothing outlives the wrapper.
(
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    sleep "$HEALTHY_AFTER_S" &
    nap=$!
    wait "$nap"
    if kill -0 "$app" 2>/dev/null; then
        rm -f "$GUARD"
        sync
        log "healthy after ${HEALTHY_AFTER_S}s"
    fi
) &
timer=$!

# `wait` returns early when a trapped signal arrives; keep waiting until the app itself is gone.
while :; do
    wait "$app"
    rc=$?
    kill -0 "$app" 2>/dev/null || break
done
kill -TERM "$timer" 2>/dev/null
wait "$timer" 2>/dev/null
if [ "$stopping" = 1 ]; then
    log "stopped on request"
    exit 0
fi
log "app exited (rc=$rc)"
exit "$rc"
