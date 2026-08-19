#!/usr/bin/env bash
# Integration test for swallow-embed, run inside a throwaway Xephyr +
# openbox session so it never touches the real desktop. Same pattern
# as test-generic.sh in this same directory.
#
# Drives an interactive xterm by typing into it via xdotool (the same
# way a user actually runs this), rather than pre-baking the command
# into xterm -e: xterm's default interactive shell can rewrite the
# window title via its own prompt escape sequences, racing any
# title-based window lookup, so windows are found by PID instead.
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
    rm -f /tmp/swallow-embed-test-marker
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

window_for_pid() { DISPLAY=":$XDISP" xdotool search --onlyvisible --pid "$1" 2>/dev/null | head -n1; }

child_count() { DISPLAY=":$XDISP" xwininfo -id "$1" -children 2>/dev/null | grep -c '^ *0x'; }

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

# --- scenario: reparent, resize, real keyboard input, close -------------
# A plain interactive xterm stands in for "the terminal you run this
# from". The swallow-embed command is TYPED into it via xdotool, the
# same way a user actually invokes this, targeting a second, inner
# xterm. By the time it runs, the outer xterm is already mapped and
# focused, so _NET_ACTIVE_WINDOW already points at it.
run_embed_scenario() {
    log "--- scenario: reparent + resize + input + close ---"
    rm -f /tmp/swallow-embed-test-marker

    DISPLAY=":$XDISP" xterm >/tmp/swallow-embed-test-outer.log 2>&1 &
    local outer_pid=$!

    local outer_win=""
    wait_for 10 bash -c "[ -n \"\$(DISPLAY=:$XDISP xdotool search --onlyvisible --pid $outer_pid 2>/dev/null)\" ]" || {
        fail "outer terminal window never appeared"
        kill "$outer_pid" 2>/dev/null
        return
    }
    outer_win=$(window_for_pid "$outer_pid")
    pass "outer terminal window appeared (id $outer_win)"

    # xterm creates its own internal VT100 widget child window shortly
    # after mapping, unrelated to swallow-embed; settle past that
    # before taking the "before" baseline, or it gets miscounted as
    # something swallow-embed added.
    local before_children prev=-1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        before_children=$(child_count "$outer_win")
        [ "$before_children" = "$prev" ] && break
        prev=$before_children
        sleep 0.3
    done

    DISPLAY=":$XDISP" xdotool windowactivate --sync "$outer_win" >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool type -- \
        "$BIN xterm -e bash -c 'cat > /tmp/swallow-embed-test-marker'"
    DISPLAY=":$XDISP" xdotool key Return

    local ticks=25
    while [ "$ticks" -gt 0 ]; do
        [ "$(child_count "$outer_win")" -gt "$before_children" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ "$(child_count "$outer_win")" -gt "$before_children" ]; then
        pass "inner app window was reparented as a child of the outer terminal window"
    else
        fail "inner app window never showed up as a child of the outer terminal window"
        kill "$outer_pid" 2>/dev/null
        return
    fi

    # Confirm root has no OTHER new direct child besides the outer
    # terminal -- that's the specific thing an earlier version of this
    # prototype (which created a fresh container instead of reusing
    # the caller's own window) got wrong. `xdotool search` recurses
    # the whole tree, so it would find the reparented child too, at
    # any depth; only root's direct children matter here.
    local other_toplevel
    other_toplevel=$(DISPLAY=":$XDISP" xwininfo -root -children 2>/dev/null \
        | grep -oP '^\s+\K0x[0-9a-f]+(?=\s+"[^"]*":\s+\("xterm")' | grep -vx "$outer_win" | wc -l)
    if [ "$other_toplevel" -eq 0 ]; then
        pass "inner app is not independently reachable as a top-level window (truly embedded)"
    else
        fail "inner app is still reachable as its own top-level window ($other_toplevel matches)"
    fi

    # Size: embedded app should fill the outer terminal exactly.
    local outer_geom inner_win inner_geom
    inner_win=$(DISPLAY=":$XDISP" xwininfo -id "$outer_win" -children 2>/dev/null \
        | grep -oP '^\s+\K0x[0-9a-f]+(?=\s+"[^"]*":\s+\("xterm")' | head -n1)
    outer_geom=$(DISPLAY=":$XDISP" xdotool getwindowgeometry --shell "$outer_win" 2>/dev/null \
        | sed -n 's/^WIDTH=\(.*\)/\1/p;s/^HEIGHT=\(.*\)/\1/p' | paste -sd, -)
    inner_geom=$(DISPLAY=":$XDISP" xdotool getwindowgeometry --shell "$inner_win" 2>/dev/null \
        | sed -n 's/^WIDTH=\(.*\)/\1/p;s/^HEIGHT=\(.*\)/\1/p' | paste -sd, -)
    if [ -n "$inner_win" ] && [ "$outer_geom" = "$inner_geom" ]; then
        pass "embedded app was resized to fill the terminal exactly ($inner_geom)"
    else
        fail "embedded app size ($inner_geom) does not match terminal size ($outer_geom)"
    fi

    # Real keyboard input, via XTEST (windowactivate + type), not a
    # synthetic XSendEvent (xterm legitimately ignores those).
    DISPLAY=":$XDISP" xdotool windowactivate --sync "$outer_win" >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool type "hello-from-test"
    sleep 0.3
    DISPLAY=":$XDISP" xdotool key ctrl+d
    wait_for 5 test -s /tmp/swallow-embed-test-marker
    if [ "$(cat /tmp/swallow-embed-test-marker 2>/dev/null)" = "hello-from-test" ]; then
        pass "keyboard input reached the embedded app"
    else
        fail "keyboard input did not reach the embedded app (got: '$(cat /tmp/swallow-embed-test-marker 2>/dev/null)')"
    fi

    # ctrl+d already made the inner xterm's cat exit, which makes the
    # inner xterm exit, which makes swallow-embed exit, leaving the
    # outer terminal's own shell running and its window intact.
    wait_for 5 bash -c "[ \"\$(DISPLAY=:$XDISP xwininfo -id $outer_win -children 2>/dev/null | grep -c '^ *0x')\" -le $before_children ]"
    if [ "$(child_count "$outer_win")" -le "$before_children" ]; then
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

# --- scenario: Ctrl+Q closes the embedded app, terminal survives -------
run_ctrlq_scenario() {
    log "--- scenario: Ctrl+Q closes app, terminal survives ---"

    DISPLAY=":$XDISP" xterm >/tmp/swallow-embed-test-outer2.log 2>&1 &
    local outer_pid=$!

    wait_for 10 bash -c "[ -n \"\$(DISPLAY=:$XDISP xdotool search --onlyvisible --pid $outer_pid 2>/dev/null)\" ]" || {
        fail "outer terminal window never appeared"
        kill "$outer_pid" 2>/dev/null
        return
    }
    local outer_win
    outer_win=$(window_for_pid "$outer_pid")
    # xterm creates its own internal VT100 widget child window shortly
    # after mapping, unrelated to swallow-embed; settle past that
    # before taking the "before" baseline, or it gets miscounted as
    # something swallow-embed added.
    local before_children prev=-1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        before_children=$(child_count "$outer_win")
        [ "$before_children" = "$prev" ] && break
        prev=$before_children
        sleep 0.3
    done

    DISPLAY=":$XDISP" xdotool windowactivate --sync "$outer_win" >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool type -- "$BIN xterm -e sleep 30"
    DISPLAY=":$XDISP" xdotool key Return

    local ticks=25
    while [ "$ticks" -gt 0 ]; do
        [ "$(child_count "$outer_win")" -gt "$before_children" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ "$(child_count "$outer_win")" -le "$before_children" ]; then
        fail "inner app never got embedded, can't test Ctrl+Q"
        kill "$outer_pid" 2>/dev/null
        return
    fi

    DISPLAY=":$XDISP" xdotool windowactivate --sync "$outer_win" >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool key ctrl+q

    wait_for 5 bash -c "[ \"\$(DISPLAY=:$XDISP xwininfo -id $outer_win -children 2>/dev/null | grep -c '^ *0x')\" -le $before_children ]"
    if [ "$(child_count "$outer_win")" -le "$before_children" ]; then
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
