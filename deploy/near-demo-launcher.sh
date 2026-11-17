#!/bin/sh
# `near-demo` from any directory: puts the frozen agent console demo back on the board. Install it once on the Mac:
#
#   install -m 755 deploy/near-demo-launcher.sh ~/.local/bin/near-demo
#
# It keeps its own clone of the tag only (~/.cache/near-demo/src), forces it to the tag on every run, and runs that
# tag's deploy/near-demo.sh with the same arguments. No working tree or branch of yours is used or touched, so the demo
# still builds after the product code changes or deletes app/lib/agents. Without a network it uses the tag it fetched
# before. NEAR_DEMO_TAG picks another tag, NEAR_DEMO_REPO another remote, NEAR_DEMO_CACHE another cache folder.
set -eu
TAG=${NEAR_DEMO_TAG:-demo/agent-console-v1}
REPO=${NEAR_DEMO_REPO:-https://github.com/tony496s/near-orangepi4pro.git}
SRC=${NEAR_DEMO_CACHE:-$HOME/.cache/near-demo}/src
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE  # in case it runs from a git hook

g() { git -C "$SRC" "$@"; }

if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$SRC"
    git -c init.defaultBranch=demo -C "$SRC" init -q
fi
if g remote get-url origin >/dev/null 2>&1; then
    g remote set-url origin "$REPO"
else
    g remote add origin "$REPO"
fi
echo "near-demo: fetching $TAG"
if ! g fetch -q --depth=1 --force --no-tags origin "+refs/tags/$TAG:refs/tags/$TAG"; then
    if g rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null; then
        echo "near-demo: could not fetch $TAG from $REPO, using the copy fetched before" >&2
    else
        echo "near-demo: cannot get $TAG from $REPO (network, or no such tag)" >&2
        exit 1
    fi
fi
# Forced every run, build output included (a clean build takes about 10 s), so nothing but the tag goes into the build.
g -c advice.detachedHead=false checkout -q --force --detach "refs/tags/$TAG^{commit}"
g clean -q -ffdx
exec "$SRC/deploy/near-demo.sh" "$@"
