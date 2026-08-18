#!/usr/bin/env bash
# Integration test for swallow-embed, run inside a throwaway Xephyr +
# openbox session so it never touches the real desktop. Same pattern
# as test-generic.sh in this same directory.
#
# Requires: Xephyr, openbox, xdotool, xwininfo. Skips (exit 0) if
# missing.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../bin/swallow-embed"

PASS=0
FAIL=0
XDISP=""
XEPHYR_PID=""
OPENBOX_PID=""

log()  { printf '%s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); log "  FAIL: $*"; }

cleanup() {
    [ -n "$OPENBOX_PID" ] && kill "$OPENBOX_PID" >/dev/null 2>&1
    [ -n "$XEPHYR_PID" ] && kill "$XEPHYR_PID" >/dev/null 2>&1
    wait >/dev/null 2>&1
    rm -f /tmp/swallow-embed-test-marker /tmp/swallow-embed-test-exit
}
trap cleanup EXIT INT TERM

require() {
    command -v "$1" >/dev/null 2>&1 || {
        log "swallow-embed test: '$1' not found, skipping"
        exit 0
    }
}
require Xephyr
require openbox
require xdotool
require xwininfo
require xterm

[ -x "$BIN" ] || { log "swallow-embed test: $BIN not built (run make)"; exit 1; }

wait_for() { # wait_for <timeout_seconds> <command...>
    local ticks=$(( $1 * 5 ))
    shift
    while ! "$@" >/dev/null 2>&1; do
        ticks=$((ticks - 1))
        [ "$ticks" -le 0 ] && return 1
        sleep 0.2
    done
    return 0
}

find_window_by_name() { DISPLAY=":$XDISP" xdotool search --name "$1" 2>/dev/null | head -n1; }

# --- start a private X server + WM, exactly like tests/test-generic.sh --
for cand in $(seq 50 199); do
    if [ ! -e "/tmp/.X${cand}-lock" ]; then
        XDISP=$cand
        break
    fi
done
[ -n "$XDISP" ] || { log "swallow-embed test: no free X display found"; exit 1; }

log "Starting Xephyr on display :$XDISP"
Xephyr -br -ac -noreset -screen 800x600 ":$XDISP" >/tmp/swallow-embed-test-xephyr.log 2>&1 &
XEPHYR_PID=$!

wait_for 10 test -S "/tmp/.X11-unix/X${XDISP}" || {
    log "swallow-embed test: Xephyr did not start"; exit 1
}

log "Starting openbox"
DISPLAY=":$XDISP" openbox >/tmp/swallow-embed-test-openbox.log 2>&1 &
OPENBOX_PID=$!

wait_for 10 bash -c \
    "DISPLAY=:$XDISP xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id'" || {
    log "swallow-embed test: openbox did not become ready"; exit 1
}

# --- scenario 1: reparenting, sizing, and real keyboard input ----------
# The "terminal" is an outer xterm. It runs swallow-embed itself as its
# shell command, targeting a second, inner xterm. By the time
# swallow-embed starts, the outer xterm is already mapped and (openbox's
# default) focused, so _NET_ACTIVE_WINDOW already points at it -- the
# same way a real terminal would be active when a user runs this by
# hand.
run_embed_scenario() {
    log "--- scenario: reparent + resize + input ---"
    rm -f /tmp/swallow-embed-test-marker

    DISPLAY=":$XDISP" xterm -T outer-terminal -e bash -c \
        "'$BIN' xterm -T inner-app -e bash -c 'cat > /tmp/swallow-embed-test-marker'" &
    local outer_pid=$!

    local outer_win
    outer_win=$(find_window_by_name "outer-terminal")
    wait_for 10 bash -c "DISPLAY=:$XDISP xdotool search --name outer-terminal >/dev/null 2>&1" || {
        fail "outer terminal window never appeared"; kill "$outer_pid" 2>/dev/null; return
    }
    outer_win=$(find_window_by_name "outer-terminal")

    # The inner app's window should end up as a REPARENTED CHILD of the
    # outer terminal's own window -- not a new top-level window of its
    # own. This is the whole point of this design (see swallow-embed.c's
    # top comment): no new window ever appears.
    local inner_win=""
    local ticks=25
    while [ "$ticks" -gt 0 ]; do
        inner_win=$(DISPLAY=":$XDISP" xwininfo -id "$outer_win" -children 2>/dev/null \
            | grep -oP '0x[0-9a-f]+(?= "inner-app")')
        [ -n "$inner_win" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ -n "$inner_win" ]; then
        pass "inner app window was reparented as a child of the outer terminal window"
    else
        fail "inner app window never showed up as a child of the outer terminal window"
        kill "$outer_pid" 2>/dev/null
        return
    fi

    # Confirm no NEW top-level window was created on root for the app --
    # this is the specific thing the earlier "creates a fresh container"
    # version got wrong.
    local toplevel_count
    toplevel_count=$(DISPLAY=":$XDISP" xdotool search --name "inner-app" 2>/dev/null | wc -l)
    if [ "$toplevel_count" -eq 0 ]; then
        pass "inner app is not independently reachable as a top-level window (truly embedded, not just another window)"
    else
        fail "inner app is still reachable as its own top-level window ($toplevel_count matches) -- not really embedded"
    fi

    # Size: should match the outer terminal's own client area.
    local outer_geom inner_geom
    outer_geom=$(DISPLAY=":$XDISP" xdotool getwindowgeometry --shell "$outer_win" 2>/dev/null \
        | sed -n 's/^WIDTH=\(.*\)/\1/p;s/^HEIGHT=\(.*\)/\1/p' | paste -sd, -)
    inner_geom=$(DISPLAY=":$XDISP" xdotool getwindowgeometry --shell "$inner_win" 2>/dev/null \
        | sed -n 's/^WIDTH=\(.*\)/\1/p;s/^HEIGHT=\(.*\)/\1/p' | paste -sd, -)
    if [ "$outer_geom" = "$inner_geom" ]; then
        pass "embedded app was resized to fill the terminal exactly ($inner_geom)"
    else
        fail "embedded app size ($inner_geom) does not match terminal size ($outer_geom)"
    fi

    # Real keyboard input, via XTEST (windowactivate + type), not a
    # synthetic XSendEvent (xterm legitimately ignores those).
    DISPLAY=":$XDISP" xdotool windowactivate --sync "$outer_win" >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool type "hello-from-test"
    DISPLAY=":$XDISP" xdotool key ctrl+d
    wait_for 5 test -s /tmp/swallow-embed-test-marker
    if [ "$(cat /tmp/swallow-embed-test-marker 2>/dev/null)" = "hello-from-test" ]; then
        pass "keyboard input reached the embedded app"
    else
        fail "keyboard input did not reach the embedded app (got: '$(cat /tmp/swallow-embed-test-marker 2>/dev/null)')"
    fi

    # ctrl+d already made the inner xterm's cat exit, which makes the
    # inner xterm itself exit, which should make swallow-embed exit too,
    # leaving the outer terminal's own shell running and its window
    # intact.
    wait_for 5 bash -c "! kill -0 $outer_pid 2>/dev/null || ! DISPLAY=:$XDISP xwininfo -id $outer_win -children 2>/dev/null | grep -q inner-app"
    if ! DISPLAY=":$XDISP" xwininfo -id "$outer_win" -children 2>/dev/null | grep -q "inner-app"; then
        pass "embedded app cleanly gone after it exited on its own"
    else
        fail "embedded app window still present after it should have exited"
    fi
    if DISPLAY=":$XDISP" xwininfo -id "$outer_win" >/dev/null 2>&1; then
        pass "outer terminal window survived (was not destroyed by the embed/unembed)"
    else
        fail "outer terminal window is gone -- should have survived"
    fi

    kill "$outer_pid" 2>/dev/null
}

# --- scenario 2: Ctrl+Q closes the embedded app, terminal survives -----
run_ctrlq_scenario() {
    log "--- scenario: Ctrl+Q closes app, terminal survives ---"

    DISPLAY=":$XDISP" xterm -T outer-terminal2 -e bash -c \
        "'$BIN' xterm -T inner-app2 -e 'sleep 30'" &
    local outer_pid=$!

    wait_for 10 bash -c "DISPLAY=:$XDISP xdotool search --name outer-terminal2 >/dev/null 2>&1" || {
        fail "outer terminal window never appeared"; kill "$outer_pid" 2>/dev/null; return
    }
    local outer_win
    outer_win=$(find_window_by_name "outer-terminal2")

    local ticks=25
    while [ "$ticks" -gt 0 ]; do
        DISPLAY=":$XDISP" xwininfo -id "$outer_win" -children 2>/dev/null | grep -q "inner-app2" && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if ! DISPLAY=":$XDISP" xwininfo -id "$outer_win" -children 2>/dev/null | grep -q "inner-app2"; then
        fail "inner app never got embedded, can't test Ctrl+Q"
        kill "$outer_pid" 2>/dev/null
        return
    fi

    DISPLAY=":$XDISP" xdotool windowactivate --sync "$outer_win" >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool key ctrl+q

    wait_for 5 bash -c "! DISPLAY=:$XDISP xwininfo -id $outer_win -children 2>/dev/null | grep -q inner-app2"
    if ! DISPLAY=":$XDISP" xwininfo -id "$outer_win" -children 2>/dev/null | grep -q "inner-app2"; then
        pass "Ctrl+Q closed the embedded app"
    else
        fail "Ctrl+Q did not close the embedded app"
    fi
    if DISPLAY=":$XDISP" xwininfo -id "$outer_win" >/dev/null 2>&1; then
        pass "outer terminal window survived Ctrl+Q"
    else
        fail "outer terminal window is gone after Ctrl+Q -- should have survived"
    fi

    kill "$outer_pid" 2>/dev/null
}

run_embed_scenario
run_ctrlq_scenario

log ""
log "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
