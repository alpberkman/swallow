#!/usr/bin/env bash
# Integration tests for swallow, run inside a throwaway Xephyr + openbox
# session so they don't touch the real desktop.
#
# Requires: Xephyr, openbox, xdotool, xprop. Skips (exit 0) if missing.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SWALLOW="$ROOT_DIR/swallow"
FORK_HELPER="$SCRIPT_DIR/fork_exec_helper"

PASS=0
FAIL=0
XDISP=""
XEPHYR_PID=""
OPENBOX_PID=""
CLEANUP_PIDS=()

log()  { printf '%s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); log "  FAIL: $*"; }

cleanup() {
    for pid in "${CLEANUP_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1
    done
    [ -n "$OPENBOX_PID" ] && kill "$OPENBOX_PID" >/dev/null 2>&1
    [ -n "$XEPHYR_PID" ] && kill "$XEPHYR_PID" >/dev/null 2>&1
    wait >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

require() {
    command -v "$1" >/dev/null 2>&1 || {
        log "swallow tests: '$1' not found, skipping test suite"
        exit 0
    }
}
require Xephyr
require openbox
require xdotool
require xprop
require xmessage

[ -x "$SWALLOW" ] || { log "swallow tests: $SWALLOW not built"; exit 1; }
[ -x "$FORK_HELPER" ] || { log "swallow tests: $FORK_HELPER not built"; exit 1; }

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

find_window() { DISPLAY=":$XDISP" xdotool search --name "$1" 2>/dev/null | head -n1; }

window_mapped() {
    DISPLAY=":$XDISP" xwininfo -id "$1" 2>/dev/null | grep -q "IsViewable"
}

window_geom() {
    DISPLAY=":$XDISP" xdotool getwindowgeometry --shell "$1" 2>/dev/null \
        | sed -n 's/^X=\(.*\)/\1/p;s/^Y=\(.*\)/\1/p;s/^WIDTH=\(.*\)/\1/p;s/^HEIGHT=\(.*\)/\1/p' \
        | paste -sd, -
}

# geom_close g1 g2 tol: true if every component (x,y,w,h) of two
# "x,y,w,h" strings is within tol of the other. Decorations can differ by a
# few pixels between window types/themes, so exact equality isn't realistic.
geom_close() {
    local IFS=,
    local -a a=($1) b=($2)
    local tol="$3" i diff
    for i in 0 1 2 3; do
        diff=$(( a[i] - b[i] ))
        [ "$diff" -lt 0 ] && diff=$(( -diff ))
        [ "$diff" -gt "$tol" ] && return 1
    done
    return 0
}

# --- start a private X server + WM ------------------------------------
for cand in $(seq 50 199); do
    if [ ! -e "/tmp/.X${cand}-lock" ]; then
        XDISP=$cand
        break
    fi
done
[ -n "$XDISP" ] || { log "swallow tests: no free X display found"; exit 1; }

log "Starting Xephyr on display :$XDISP"
Xephyr -br -ac -noreset -screen 800x600 ":$XDISP" >/tmp/swallow-test-xephyr.log 2>&1 &
XEPHYR_PID=$!

wait_for 10 test -S "/tmp/.X11-unix/X${XDISP}" || {
    log "swallow tests: Xephyr did not start"
    exit 1
}

log "Starting openbox"
DISPLAY=":$XDISP" openbox >/tmp/swallow-test-openbox.log 2>&1 &
OPENBOX_PID=$!

# xprop always exits 0, even when the atom doesn't exist ("no such atom on
# any window"), so readiness has to be judged from its output, not its
# exit code.
wait_for 10 bash -c \
    "DISPLAY=:$XDISP xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id'" || {
    log "swallow tests: openbox did not become ready"
    exit 1
}

# --- shared assertions ---------------------------------------------------
# Given a swallow run already in flight (app window found), verifies:
#   1. the terminal disappears (unmapped, not just minimized -- no leftover
#      taskbar/pager entry)
#   2. killing the app window restores the terminal, in the same place
verify_swallow_behavior() {
    local desc="$1" term_win="$2" app_win="$3" term_geom_before="$4" swallow_pid="$5"

    local app_geom
    local ticks=10
    while [ "$ticks" -gt 0 ]; do
        app_geom="$(window_geom "$app_win")"
        geom_close "$app_geom" "$term_geom_before" 20 && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if geom_close "$app_geom" "$term_geom_before" 20; then
        pass "$desc: app window took the terminal's place ($app_geom ~ $term_geom_before)"
    else
        fail "$desc: app window geometry ($app_geom) doesn't match terminal's ($term_geom_before)"
    fi

    local ticks=15
    while [ "$ticks" -gt 0 ]; do
        window_mapped "$term_win" || break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if ! window_mapped "$term_win"; then
        pass "$desc: terminal was hidden (unmapped, not just minimized)"
    else
        fail "$desc: terminal was not hidden"
    fi

    local app_pid
    app_pid="$(DISPLAY=":$XDISP" xdotool getwindowpid "$app_win" 2>/dev/null)"
    if [ -n "$app_pid" ]; then
        kill -TERM "$app_pid" >/dev/null 2>&1
    else
        DISPLAY=":$XDISP" xdotool windowkill "$app_win" >/dev/null 2>&1
    fi

    if wait_for 10 bash -c "! kill -0 $swallow_pid 2>/dev/null"; then
        pass "$desc: swallow exited after app window closed"
    else
        fail "$desc: swallow did not exit after app window closed"
    fi

    ticks=15
    while [ "$ticks" -gt 0 ]; do
        window_mapped "$term_win" && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if window_mapped "$term_win"; then
        pass "$desc: terminal was restored"
    else
        fail "$desc: terminal was not restored"
    fi

    local term_geom_after
    term_geom_after="$(window_geom "$term_win")"
    if [ "$term_geom_after" = "$term_geom_before" ]; then
        pass "$desc: terminal kept its geometry ($term_geom_before)"
    else
        fail "$desc: terminal geometry changed (was $term_geom_before, now $term_geom_after)"
    fi
}

# Sets up a terminal window, activates it, and moves/sizes it to something
# deliberately non-default so later geometry checks are meaningful. Prints
# "term_win,term_geom_before|xterm_pid" on success, nothing on failure.
setup_terminal() {
    local desc="$1" term_title="$2"

    DISPLAY=":$XDISP" xterm -title "$term_title" -e "sh -c 'while :; do sleep 3600; done'" \
        >/tmp/swallow-test-xterm.log 2>&1 &
    local xterm_pid=$!
    CLEANUP_PIDS+=("$xterm_pid")

    local term_win=""
    local ticks=50
    while [ -z "$term_win" ] && [ "$ticks" -gt 0 ]; do
        term_win="$(find_window "$term_title")"
        [ -n "$term_win" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ -z "$term_win" ]; then
        fail "$desc: terminal window never appeared"
        kill "$xterm_pid" >/dev/null 2>&1
        return 1
    fi

    DISPLAY=":$XDISP" xdotool windowactivate --sync "$term_win" >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool windowmove "$term_win" 60 70 >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool windowsize "$term_win" 500 350 >/dev/null 2>&1
    sleep 0.3
    echo "$term_win,$(window_geom "$term_win")|$xterm_pid"
    return 0
}

# --- scenario: normal exec, and fork+exec (double-fork daemonize) --------
run_scenario() {
    local desc="$1"; shift
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local app_title="SwallowTestApp-$$-$RANDOM"

    log "Scenario: $desc"

    local setup term_win term_geom_before xterm_pid
    setup="$(setup_terminal "$desc" "$term_title")" || return
    term_win="${setup%%,*}"
    term_geom_before="${setup#*,}"; term_geom_before="${term_geom_before%%|*}"
    xterm_pid="${setup##*|}"

    DISPLAY=":$XDISP" "$@" "$SWALLOW" xmessage -title "$app_title" -center "hello from $desc" \
        >/tmp/swallow-test-run.log 2>&1 &
    local swallow_pid=$!
    CLEANUP_PIDS+=("$swallow_pid")

    local app_win=""
    local ticks=50
    while [ -z "$app_win" ] && [ "$ticks" -gt 0 ]; do
        app_win="$(find_window "$app_title")"
        [ -n "$app_win" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ -z "$app_win" ]; then
        fail "$desc: app window never appeared"
        kill "$swallow_pid" "$xterm_pid" >/dev/null 2>&1
        return
    fi
    pass "$desc: app window appeared"

    verify_swallow_behavior "$desc" "$term_win" "$app_win" "$term_geom_before" "$swallow_pid"

    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

# --- scenario: detached launcher (D-Bus/kdeinit single-instance style) ---
# Reproduces the Kate case: swallow launches a short-lived "stub" that hands
# the real work off to a pre-existing, independent process sharing no
# process-tree relationship with swallow's child at all (stood in for here
# by a small daemon reading requests off a fifo, started before swallow
# ever runs). No PID/pgid heuristic can identify that daemon's window as
# "belonging" to what swallow launched -- this is what motivated matching
# on window creation order instead.
run_detached_scenario() {
    local desc="detached launcher (D-Bus/kdeinit single-instance style)"
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local app_title="SwallowTestApp-$$-$RANDOM"
    local fifo="/tmp/swallow-test-fifo-$$"

    log "Scenario: $desc"

    local setup term_win term_geom_before xterm_pid
    setup="$(setup_terminal "$desc" "$term_title")" || return
    term_win="${setup%%,*}"
    term_geom_before="${setup#*,}"; term_geom_before="${term_geom_before%%|*}"
    xterm_pid="${setup##*|}"

    mkfifo "$fifo" 2>/dev/null
    ( while read -r line; do DISPLAY=":$XDISP" sh -c "$line" & done < "$fifo" ) &
    local daemon_pid=$!
    CLEANUP_PIDS+=("$daemon_pid")

    # The "stub": like kate's real binary, forwards the request to the
    # unrelated daemon above (standing in for D-Bus) and exits immediately.
    DISPLAY=":$XDISP" "$SWALLOW" sh -c "echo 'xmessage -title \"$app_title\" -center hi' > $fifo" \
        >/tmp/swallow-test-run.log 2>&1 &
    local swallow_pid=$!
    CLEANUP_PIDS+=("$swallow_pid")

    local app_win=""
    local ticks=50
    while [ -z "$app_win" ] && [ "$ticks" -gt 0 ]; do
        app_win="$(find_window "$app_title")"
        [ -n "$app_win" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ -z "$app_win" ]; then
        fail "$desc: app window never appeared"
        kill "$swallow_pid" "$xterm_pid" "$daemon_pid" >/dev/null 2>&1
        rm -f "$fifo"
        return
    fi
    pass "$desc: app window appeared"

    verify_swallow_behavior "$desc" "$term_win" "$app_win" "$term_geom_before" "$swallow_pid"

    kill "$xterm_pid" "$daemon_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
    rm -f "$fifo"
}

run_scenario "direct exec"
run_scenario "fork+exec launcher (double-fork daemonize style)" "$FORK_HELPER"
run_detached_scenario

log ""
log "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
