#!/bin/bash
# Exercise a swallow-* binary against the scenarios that matter:
#   1. direct app launch (app sets its own _NET_WM_PID, doesn't detach)
#   2. detached/single-instance-style app (launched process forks a window
#      and exits immediately -- breaks naive PID-ancestry matching)
#   3. a command that never opens a window (should give up, not hang, and
#      never touch the terminal window)
#   4. (i3-msg/jq only) the app's tiled window immediately takes over the
#      terminal's exact former size
#   5. (i3-msg/jq only) a resize while the app is open survives into the
#      restored terminal's size
#
# By default this runs against whatever i3 session $DISPLAY already points
# at (a real, already-running one). Pass --xephyr as the first argument to
# instead spin up a disposable nested Xephyr+i3 session and run against
# that, so nothing on your actual desktop gets touched -- useful for
# swallow-i3.sh, since plain swallow (src/swallow.c) doesn't need i3 at all.
#
# Usage: ./test-i3.sh [--xephyr] <binary> [binary2 ...]
# Example: ./test-i3.sh ../bin/swallow
# Example: ./test-i3.sh --xephyr ./swallow-i3.sh

set -u
cd "$(dirname "$0")"

pass=0
fail=0

note() { echo "  $*"; }
ok()   { echo "  OK: $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $*"; fail=$((fail+1)); }

XEPHYR_PID=""
I3_PID=""
I3_CONF=""
I3_SOCK=""

cleanup() {
    pkill -x xterm >/dev/null 2>&1
    [ -n "$I3_PID" ] && kill "$I3_PID" >/dev/null 2>&1
    [ -n "$XEPHYR_PID" ] && kill "$XEPHYR_PID" >/dev/null 2>&1
    [ -n "$I3_CONF" ] && rm -f "$I3_CONF"
    [ -n "$I3_SOCK" ] && rm -f "$I3_SOCK"
}
trap cleanup EXIT

# Starts a disposable nested Xephyr+i3 session and points $DISPLAY/$I3SOCK at
# it for the rest of this script's run -- every command below is a bare
# xterm/i3-msg call with no explicit DISPLAY, so exporting both here is
# enough to retarget everything without touching the test functions
# themselves. $I3SOCK must be exported explicitly rather than left to X-atom
# auto-discovery: if a real i3 session is already running on your desktop,
# its $I3SOCK is typically already set in your shell/session environment and
# would otherwise silently take precedence over the nested instance for both
# i3-msg and swallow-i3.sh (confirmed -- without this, i3-msg's queries and
# swallow-i3.sh itself both quietly talked to the *live* i3, not the nested
# one).
setup_xephyr() {
    for tool in Xephyr i3 i3-msg jq; do
        command -v "$tool" >/dev/null || {
            echo "test.sh: --xephyr needs '$tool' on PATH" >&2
            exit 1
        }
    done

    local n disp_num=""
    for n in $(seq 1 50); do
        [ -S "/tmp/.X11-unix/X$n" ] || { disp_num=$n; break; }
    done
    if [ -z "$disp_num" ]; then
        echo "test.sh: no free X display slot found" >&2
        exit 1
    fi
    local disp=":$disp_num"

    Xephyr "$disp" -screen 1280x800 -ac >/tmp/swallow-test-xephyr.log 2>&1 &
    XEPHYR_PID=$!
    for _ in $(seq 1 50); do
        DISPLAY="$disp" xdpyinfo >/dev/null 2>&1 && break
        sleep 0.1
    done
    if ! DISPLAY="$disp" xdpyinfo >/dev/null 2>&1; then
        echo "test.sh: Xephyr on $disp never came up" >&2
        cat /tmp/swallow-test-xephyr.log >&2
        exit 1
    fi

    I3_CONF=$(mktemp)
    echo "# minimal i3 config for nested test session" > "$I3_CONF"
    I3_SOCK="/tmp/swallow-test-i3sock-$$"
    rm -f "$I3_SOCK"
    I3SOCK="$I3_SOCK" DISPLAY="$disp" i3 -c "$I3_CONF" >/tmp/swallow-test-i3.log 2>&1 &
    I3_PID=$!
    for _ in $(seq 1 50); do
        [ -S "$I3_SOCK" ] && break
        sleep 0.1
    done
    if [ ! -S "$I3_SOCK" ]; then
        echo "test.sh: i3 on $disp never came up" >&2
        cat /tmp/swallow-test-i3.log >&2
        exit 1
    fi

    export DISPLAY="$disp"
    export I3SOCK="$I3_SOCK"
    echo "=== nested i3 session up on $disp (Xephyr pid $XEPHYR_PID, i3 pid $I3_PID, socket $I3_SOCK) ==="
}

USE_XEPHYR=0
if [ "${1:-}" = "--xephyr" ]; then
    USE_XEPHYR=1
    shift
fi
[ "$USE_XEPHYR" -eq 1 ] && setup_xephyr

map_state() {
    xwininfo -id "$1" 2>/dev/null | grep "Map State" | awk '{print $NF}'
}

find_win() {
    xwininfo -root -tree | grep -F "$1" | grep -oE '0x[0-9a-f]+' | head -1
}

# Spawn a fake "terminal" xterm and echo back "<pid> <winid>".
spawn_term() {
    local tag=$1
    xterm -T "$tag" -e sleep 60 &
    local tpid=$!
    sleep 0.7
    local twid
    twid=$(find_win "$tag")
    echo "$tpid $twid"
}

test_direct() {
    local bin=$1 tag="T_DIRECT_$$"
    echo "--- $bin: direct app launch ---"
    read -r tpid twid < <(spawn_term "$tag")
    if [ -z "$twid" ]; then bad "could not find fake terminal window"; kill "$tpid" 2>/dev/null; return; fi

    WINDOWID="$((twid))" "$bin" xterm -T "A_DIRECT_$$" -e sleep 30 &
    local spid=$!
    sleep 1.2

    local hidden_state
    hidden_state=$(map_state "$twid")
    [ "$hidden_state" != "IsViewable" ] && ok "terminal hidden after launch ($hidden_state)" \
        || bad "terminal still IsViewable after launch"

    local awid apid
    awid=$(find_win "A_DIRECT_$$")
    apid=$(xprop -id "$awid" _NET_WM_PID 2>/dev/null | grep -oE '[0-9]+$')
    kill "$apid" 2>/dev/null
    sleep 1

    local restored_state
    restored_state=$(map_state "$twid")
    [ "$restored_state" = "IsViewable" ] && ok "terminal restored after app closed" \
        || bad "terminal not restored (state: $restored_state)"

    if kill -0 "$spid" 2>/dev/null; then bad "swallow process still running"; else ok "swallow process exited"; fi

    kill "$tpid" 2>/dev/null
    pkill -x xterm 2>/dev/null
}

test_detached() {
    local bin=$1 tag="T_DETACH_$$"
    echo "--- $bin: detached/single-instance-style app ---"
    read -r tpid twid < <(spawn_term "$tag")
    if [ -z "$twid" ]; then bad "could not find fake terminal window"; kill "$tpid" 2>/dev/null; return; fi

    WINDOWID="$((twid))" "$bin" bash -c "setsid xterm -T A_DETACH_$$ -e sleep 30 </dev/null &>/dev/null & exit 0" &
    local spid=$!
    sleep 1.5

    local hidden_state
    hidden_state=$(map_state "$twid")
    [ "$hidden_state" != "IsViewable" ] && ok "terminal hidden after detached app appeared ($hidden_state)" \
        || bad "terminal still IsViewable (detached-app matching broken)"

    local awid apid
    awid=$(find_win "A_DETACH_$$")
    apid=$(xprop -id "$awid" _NET_WM_PID 2>/dev/null | grep -oE '[0-9]+$')
    kill "$apid" 2>/dev/null
    sleep 1

    local restored_state
    restored_state=$(map_state "$twid")
    [ "$restored_state" = "IsViewable" ] && ok "terminal restored after app closed" \
        || bad "terminal not restored (state: $restored_state)"

    if kill -0 "$spid" 2>/dev/null; then bad "swallow process still running"; fi

    kill "$tpid" 2>/dev/null
    pkill -x xterm 2>/dev/null
}

test_no_window() {
    local bin=$1 tag="T_NOWIN_$$"
    echo "--- $bin: command with no window (grace timeout) ---"
    read -r tpid twid < <(spawn_term "$tag")
    if [ -z "$twid" ]; then bad "could not find fake terminal window"; kill "$tpid" 2>/dev/null; return; fi

    local before
    before=$(map_state "$twid")

    local start end
    start=$(date +%s)
    WINDOWID="$((twid))" timeout 15 "$bin" true
    end=$(date +%s)
    note "exited after $((end-start))s"

    local after
    after=$(map_state "$twid")
    [ "$before" = "IsViewable" ] && [ "$after" = "IsViewable" ] && ok "terminal untouched ($after)" \
        || bad "terminal state changed: before=$before after=$after"

    kill "$tpid" 2>/dev/null
    pkill -x xterm 2>/dev/null
}

# The app's tiled window should immediately take over the terminal's exact
# former size when it appears -- not whatever size i3's default 50/50 split
# happens to give it. Needs a sibling window in the same container, or
# there's nothing for i3 to give the freed space to/take space from; run in
# a scratch workspace so a real sibling is guaranteed regardless of whatever
# the live session's layout looks like.
# Passes for plain `swallow` too, but not for the same reason: it never
# removes the terminal from the tiling tree at all (just XUnmapWindow's
# it), so i3's own reflow naturally gives the app the freed space.
# swallow-i3.sh explicitly forces it instead (see the "new" event handler
# above), since it removes the terminal from the tree entirely via the
# scratchpad.
test_swallow_matches_size() {
    local bin=$1 tag="T_SWALLOWSZ_$$" ws="swallowtest92"
    echo "--- $bin: app should immediately take over terminal's exact tiled size ---"
    if ! command -v i3-msg >/dev/null || ! command -v jq >/dev/null; then
        note "i3-msg/jq not found, skipping"
        return
    fi

    local prev_ws
    prev_ws=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused) | .name')
    i3-msg "workspace $ws" >/dev/null

    xterm -T "SIB_$$" -e sleep 60 &
    local sibpid=$!
    sleep 0.7

    read -r tpid twid < <(spawn_term "$tag")
    if [ -z "$twid" ]; then
        bad "could not find fake terminal window"
        kill "$tpid" "$sibpid" 2>/dev/null
        i3-msg "workspace $prev_ws" >/dev/null
        return
    fi

    local term_w term_h
    read -r term_w term_h < <(xwininfo -id "$twid" | awk '/^  Width:/{w=$2} /^  Height:/{h=$2} END{print w, h}')

    WINDOWID="$((twid))" "$bin" xterm -T "A_SWALLOWSZ_$$" -e sleep 30 &
    local spid=$!
    sleep 1.2

    local awid
    awid=$(find_win "A_SWALLOWSZ_$$")
    if [ -z "$awid" ]; then
        bad "app window never appeared"
        kill "$tpid" "$sibpid" "$spid" 2>/dev/null
        pkill -x xterm 2>/dev/null
        i3-msg "workspace $prev_ws" >/dev/null
        return
    fi

    local app_w app_h
    read -r app_w app_h < <(xwininfo -id "$awid" | awk '/^  Width:/{w=$2} /^  Height:/{h=$2} END{print w, h}')

    if [ "$app_w" = "$term_w" ] && [ "$app_h" = "$term_h" ]; then
        ok "app matches terminal's tiled size (${app_w}x${app_h})"
    else
        bad "app is ${app_w}x${app_h}, expected terminal's ${term_w}x${term_h}"
    fi

    local apid
    apid=$(xprop -id "$awid" _NET_WM_PID 2>/dev/null | grep -oE '[0-9]+$')
    kill "$apid" 2>/dev/null
    sleep 1

    kill "$tpid" "$sibpid" 2>/dev/null
    pkill -x xterm 2>/dev/null
    i3-msg "workspace $prev_ws" >/dev/null
}

# If the app's tiled window gets resized while it's swallowing the terminal,
# the terminal should come back at that resized size on close, not snap back
# to whatever size it was before the app launched. Needs a sibling window in
# the same container, or i3 has nothing to trade space with when resizing
# (and errors out) -- run in a scratch workspace so a real sibling is
# guaranteed regardless of whatever the live session's layout looks like.
# Expected to FAIL for plain `swallow` as invoked here (no flags): it only
# captures the terminal's original geometry once and unmaps/maps around it
# -- matching the app's live resize is what its own --remain flag is for,
# and this harness doesn't pass it. Not a regression, just out of scope:
# the scratchpad-based rect-tracking this test checks is specific to
# swallow-i3.sh.
test_resize_survives() {
    local bin=$1 tag="T_RESIZE_$$" ws="swallowtest91"
    echo "--- $bin: app resized while swallowed, restored terminal should match ---"
    if ! command -v i3-msg >/dev/null || ! command -v jq >/dev/null; then
        note "i3-msg/jq not found, skipping"
        return
    fi

    local prev_ws
    prev_ws=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused) | .name')
    i3-msg "workspace $ws" >/dev/null

    xterm -T "SIB_$$" -e sleep 60 &
    local sibpid=$!
    sleep 0.7

    read -r tpid twid < <(spawn_term "$tag")
    if [ -z "$twid" ]; then
        bad "could not find fake terminal window"
        kill "$tpid" "$sibpid" 2>/dev/null
        i3-msg "workspace $prev_ws" >/dev/null
        return
    fi

    WINDOWID="$((twid))" "$bin" xterm -T "A_RESIZE_$$" -e sleep 30 &
    local spid=$!
    sleep 1.2

    local awid
    awid=$(find_win "A_RESIZE_$$")
    if [ -z "$awid" ]; then
        bad "app window never appeared"
        kill "$tpid" "$sibpid" "$spid" 2>/dev/null
        pkill -x xterm 2>/dev/null
        i3-msg "workspace $prev_ws" >/dev/null
        return
    fi

    i3-msg "[id=\"$((awid))\"] resize set 500 450" >/dev/null 2>&1
    sleep 0.5
    local grown_w grown_h
    read -r grown_w grown_h < <(xwininfo -id "$awid" | awk '/^  Width:/{w=$2} /^  Height:/{h=$2} END{print w, h}')

    local apid
    apid=$(xprop -id "$awid" _NET_WM_PID 2>/dev/null | grep -oE '[0-9]+$')
    kill "$apid" 2>/dev/null
    sleep 1

    local final_w final_h
    read -r final_w final_h < <(xwininfo -id "$twid" | awk '/^  Width:/{w=$2} /^  Height:/{h=$2} END{print w, h}')

    if [ "$final_w" = "$grown_w" ] && [ "$final_h" = "$grown_h" ]; then
        ok "terminal restored at resized dimensions (${final_w}x${final_h})"
    else
        bad "terminal restored at ${final_w}x${final_h}, expected the grown size ${grown_w}x${grown_h}"
    fi

    kill "$tpid" "$sibpid" 2>/dev/null
    pkill -x xterm 2>/dev/null
    i3-msg "workspace $prev_ws" >/dev/null
}

if [ $# -eq 0 ]; then
    echo "usage: $0 [--xephyr] <binary> [binary2 ...]" >&2
    exit 1
fi

for bin in "$@"; do
    echo "=== testing $bin ==="
    test_direct "$bin"
    test_detached "$bin"
    test_no_window "$bin"
    test_swallow_matches_size "$bin"
    test_resize_survives "$bin"
    echo
done

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
