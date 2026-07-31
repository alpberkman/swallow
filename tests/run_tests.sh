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

window_state() {
    DISPLAY=":$XDISP" xprop -id "$1" WM_STATE 2>/dev/null \
        | sed -n 's/.*window state: \([A-Za-z]*\).*/\1/p'
}

pid_alive() { kill -0 "$1" >/dev/null 2>&1; }

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

# --- test scenario ------------------------------------------------------
# Launches `swallow $*` "from" a terminal window (the currently active
# window), then verifies:
#   1. the app window appears and the terminal is iconified
#   2. killing the app window restores (un-iconifies) the terminal
run_scenario() {
    local desc="$1"; shift
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local app_title="SwallowTestApp-$$-$RANDOM"

    log "Scenario: $desc"

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
        return
    fi

    DISPLAY=":$XDISP" xdotool windowactivate --sync "$term_win" >/dev/null 2>&1

    DISPLAY=":$XDISP" "$@" "$SWALLOW" xmessage -title "$app_title" -center "hello from $desc" \
        >/tmp/swallow-test-run.log 2>&1 &
    local swallow_pid=$!
    CLEANUP_PIDS+=("$swallow_pid")

    local app_win=""
    ticks=50
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

    local term_state
    term_state=""
    ticks=15
    while [ "$ticks" -gt 0 ]; do
        term_state="$(window_state "$term_win")"
        [ "$term_state" = "Iconic" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ "$term_state" = "Iconic" ]; then
        pass "$desc: terminal was hidden (iconified)"
    else
        fail "$desc: terminal was not hidden (state: $term_state)"
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

    term_state=""
    ticks=15
    while [ "$ticks" -gt 0 ]; do
        term_state="$(window_state "$term_win")"
        [ "$term_state" = "Normal" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ "$term_state" = "Normal" ]; then
        pass "$desc: terminal was restored"
    else
        fail "$desc: terminal was not restored (state: $term_state)"
    fi

    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

run_scenario "direct exec"
run_scenario "fork+exec launcher (double-fork daemonize style)" "$FORK_HELPER"

log ""
log "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
