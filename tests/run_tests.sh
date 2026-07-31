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
PHANTOM_HELPER="$SCRIPT_DIR/phantom_window_helper"

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
[ -x "$PHANTOM_HELPER" ] || { log "swallow tests: $PHANTOM_HELPER not built"; exit 1; }

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
find_window_by_class() {
    # --onlyvisible matters: some apps (e.g. zathura) have unmapped helper
    # windows sharing the same WM_CLASS as their real, visible window.
    DISPLAY=":$XDISP" xdotool search --onlyvisible --class "$1" 2>/dev/null | head -n1
}

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
    # Real apps can decline to shrink below their own declared minimum size
    # (WM_NORMAL_HINTS) -- entirely legitimate, so callers with less
    # control over the app (e.g. real ones vs. our own test helpers) can
    # widen this.
    local tol="${6:-20}"

    local app_geom
    local ticks=10
    while [ "$ticks" -gt 0 ]; do
        app_geom="$(window_geom "$app_win")"
        geom_close "$app_geom" "$term_geom_before" "$tol" && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if geom_close "$app_geom" "$term_geom_before" "$tol"; then
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
# deliberately non-default so later geometry checks are meaningful. Sets
# SETUP_TERM_WIN/SETUP_TERM_GEOM/SETUP_XTERM_PID as side effects rather than
# printing them -- this is called directly (not via `$(...)`), since it
# calls fail() on error, and fail()'s counter update wouldn't survive being
# run in a subshell.
setup_terminal() {
    local desc="$1" term_title="$2"

    DISPLAY=":$XDISP" xterm -title "$term_title" -e "sh -c 'while :; do sleep 3600; done'" \
        >/tmp/swallow-test-xterm.log 2>&1 &
    SETUP_XTERM_PID=$!
    CLEANUP_PIDS+=("$SETUP_XTERM_PID")

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
        kill "$SETUP_XTERM_PID" >/dev/null 2>&1
        return 1
    fi

    DISPLAY=":$XDISP" xdotool windowactivate --sync "$term_win" >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool windowmove "$term_win" 60 70 >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool windowsize "$term_win" 500 350 >/dev/null 2>&1
    sleep 0.3
    SETUP_TERM_WIN="$term_win"
    SETUP_TERM_GEOM="$(window_geom "$term_win")"
    return 0
}

# --- scenario: normal exec, and fork+exec (double-fork daemonize) --------
run_scenario() {
    local desc="$1"; shift
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local app_title="SwallowTestApp-$$-$RANDOM"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" term_geom_before="$SETUP_TERM_GEOM" xterm_pid="$SETUP_XTERM_PID"

    # swallow must come first with its own flags before the target command
    # (--occupy makes the geometry assertion below meaningful); "$@", if
    # given, is a wrapper like fork_exec_helper that itself launches xmessage.
    DISPLAY=":$XDISP" "$SWALLOW" --occupy --timeout 30 "$@" xmessage -title "$app_title" -center "hello from $desc" \
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

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" term_geom_before="$SETUP_TERM_GEOM" xterm_pid="$SETUP_XTERM_PID"

    mkfifo "$fifo" 2>/dev/null
    ( while read -r line; do DISPLAY=":$XDISP" sh -c "$line" & done < "$fifo" ) &
    local daemon_pid=$!
    CLEANUP_PIDS+=("$daemon_pid")

    # The "stub": like kate's real binary, forwards the request to the
    # unrelated daemon above (standing in for D-Bus) and exits immediately.
    DISPLAY=":$XDISP" "$SWALLOW" --occupy --timeout 30 sh -c "echo 'xmessage -title \"$app_title\" -center hi' > $fifo" \
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

# Runs `swallow <flags...> xmessage ...` against a fresh terminal and waits
# for the app window. Sets CASE_APP_WIN/CASE_TERM_WIN/CASE_SWALLOW_PID/
# CASE_XTERM_PID as side effects (see setup_terminal for why: this calls
# fail() on error, which needs to run outside a subshell). Caller is
# responsible for calling close_flag_case when done.
run_flag_case() {
    local desc="$1"; shift
    local term_title="SwallowFlagTerm-$$-$RANDOM"
    local app_title="SwallowFlagApp-$$-$RANDOM"

    setup_terminal "$desc" "$term_title" || return 1
    CASE_TERM_WIN="$SETUP_TERM_WIN"
    CASE_XTERM_PID="$SETUP_XTERM_PID"

    DISPLAY=":$XDISP" "$SWALLOW" --timeout 30 "$@" xmessage -title "$app_title" -center "hi" \
        >/tmp/swallow-test-run.log 2>&1 &
    CASE_SWALLOW_PID=$!

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
        kill "$CASE_SWALLOW_PID" "$CASE_XTERM_PID" >/dev/null 2>&1
        return 1
    fi
    sleep 0.3
    CASE_APP_WIN="$app_win"
    return 0
}

close_flag_case() {
    local app_win="$1" term_win="$2" swallow_pid="$3" xterm_pid="$4"
    local app_pid
    app_pid="$(DISPLAY=":$XDISP" xdotool getwindowpid "$app_win" 2>/dev/null)"
    if [ -n "$app_pid" ]; then
        kill -TERM "$app_pid" >/dev/null 2>&1
    else
        DISPLAY=":$XDISP" xdotool windowkill "$app_win" >/dev/null 2>&1
    fi
    wait_for 10 bash -c "! kill -0 $swallow_pid 2>/dev/null" >/dev/null
    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

run_flags_scenario() {
    log "Scenario: placement flags"

    # --default and --occupy are mutually exclusive.
    if DISPLAY=":$XDISP" "$SWALLOW" --default --occupy true >/dev/null 2>&1; then
        fail "flags: --default + --occupy should be rejected"
    else
        pass "flags: --default + --occupy is rejected"
    fi

    # --help exits 0 and documents every flag.
    local help_out help_status
    help_out="$(DISPLAY=":$XDISP" "$SWALLOW" --help 2>&1)"
    help_status=$?
    if [ "$help_status" -eq 0 ] && echo "$help_out" | grep -q -- '--occupy' \
        && echo "$help_out" | grep -q -- '--full-screen' \
        && echo "$help_out" | grep -q -- '--remain'; then
        pass "flags: --help exits 0 and lists the flags"
    else
        fail "flags: --help output looks wrong"
    fi

    # No flags and --default should produce identical (WM-chosen) placement.
    if run_flag_case "flags: no-flags placement"; then
        local app1="$CASE_APP_WIN" geom1
        geom1="$(window_geom "$app1")"
        close_flag_case "$CASE_APP_WIN" "$CASE_TERM_WIN" "$CASE_SWALLOW_PID" "$CASE_XTERM_PID"

        if run_flag_case "flags: --default placement" --default; then
            local geom2
            geom2="$(window_geom "$CASE_APP_WIN")"
            close_flag_case "$CASE_APP_WIN" "$CASE_TERM_WIN" "$CASE_SWALLOW_PID" "$CASE_XTERM_PID"

            if [ "$geom1" = "$geom2" ]; then
                pass "flags: no-flags matches --default ($geom1)"
            else
                fail "flags: no-flags ($geom1) != --default ($geom2)"
            fi
        fi
    fi

    # Manual --x/--y/--width/--length: applied directly as the client
    # geometry, so on-screen position is offset by decoration thickness
    # (title bar/border) -- generous tolerance accounts for that.
    if run_flag_case "flags: manual geometry" --x 40 --y 50 --width 300 --length 220; then
        local geom3
        geom3="$(window_geom "$CASE_APP_WIN")"
        close_flag_case "$CASE_APP_WIN" "$CASE_TERM_WIN" "$CASE_SWALLOW_PID" "$CASE_XTERM_PID"

        if geom_close "$geom3" "40,50,300,220" 60; then
            pass "flags: manual geometry applied ($geom3 ~ 40,50,300,220)"
        else
            fail "flags: manual geometry ($geom3) doesn't match request (40,50,300,220)"
        fi
    fi

    # --full-screen: covers the whole (Xephyr) screen and sets the EWMH state.
    if run_flag_case "flags: full-screen" --full-screen; then
        local geom4 state4
        geom4="$(window_geom "$CASE_APP_WIN")"
        state4="$(DISPLAY=":$XDISP" xprop -id "$CASE_APP_WIN" _NET_WM_STATE 2>/dev/null)"
        close_flag_case "$CASE_APP_WIN" "$CASE_TERM_WIN" "$CASE_SWALLOW_PID" "$CASE_XTERM_PID"

        if geom_close "$geom4" "0,0,800,600" 5; then
            pass "flags: --full-screen covers the screen ($geom4)"
        else
            fail "flags: --full-screen geometry ($geom4) doesn't cover the screen"
        fi
        if echo "$state4" | grep -q "_NET_WM_STATE_FULLSCREEN"; then
            pass "flags: --full-screen sets _NET_WM_STATE_FULLSCREEN"
        else
            fail "flags: --full-screen didn't set _NET_WM_STATE_FULLSCREEN"
        fi
    fi

    # --full-screen composes with --occupy rather than replacing it: the
    # window's "normal" (non-fullscreen) geometry should still be forced to
    # the terminal's spot, with fullscreen layered on top.
    if run_flag_case "flags: full-screen + occupy" --occupy --full-screen; then
        local geom5 state5
        geom5="$(window_geom "$CASE_APP_WIN")"
        state5="$(DISPLAY=":$XDISP" xprop -id "$CASE_APP_WIN" _NET_WM_STATE 2>/dev/null)"
        close_flag_case "$CASE_APP_WIN" "$CASE_TERM_WIN" "$CASE_SWALLOW_PID" "$CASE_XTERM_PID"

        if geom_close "$geom5" "0,0,800,600" 5; then
            pass "flags: --occupy + --full-screen still covers the screen ($geom5)"
        else
            fail "flags: --occupy + --full-screen geometry ($geom5) doesn't cover the screen"
        fi
        if echo "$state5" | grep -q "_NET_WM_STATE_FULLSCREEN"; then
            pass "flags: --occupy + --full-screen sets _NET_WM_STATE_FULLSCREEN"
        else
            fail "flags: --occupy + --full-screen didn't set _NET_WM_STATE_FULLSCREEN"
        fi
    fi

    # Short flags (-x/-y/-w/-l/-o/-d/-f/-h) should behave identically to
    # their long forms.
    if DISPLAY=":$XDISP" "$SWALLOW" -d -o true >/dev/null 2>&1; then
        fail "flags: -d + -o should be rejected"
    else
        pass "flags: -d + -o is rejected"
    fi

    if run_flag_case "flags: short manual geometry" -x 40 -y 50 -w 300 -l 220; then
        local geom6
        geom6="$(window_geom "$CASE_APP_WIN")"
        close_flag_case "$CASE_APP_WIN" "$CASE_TERM_WIN" "$CASE_SWALLOW_PID" "$CASE_XTERM_PID"

        if geom_close "$geom6" "40,50,300,220" 60; then
            pass "flags: short manual geometry applied ($geom6 ~ 40,50,300,220)"
        else
            fail "flags: short manual geometry ($geom6) doesn't match request (40,50,300,220)"
        fi
    fi
}

# --- scenario: real applications, spawned normally ----------------------
# xmessage/xterm exercise the mechanics cheaply, but real apps are what
# actually matter. Matched by WM_CLASS since neither offers a simple way to
# give it a test-unique window title. Optional: skipped if not installed,
# so the suite stays runnable without a full PDF viewer / KDE editor.
run_real_app_scenario() {
    local desc="$1" wm_class="$2"; shift 2
    local term_title="SwallowRealTerm-$$-$RANDOM"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" term_geom_before="$SETUP_TERM_GEOM" xterm_pid="$SETUP_XTERM_PID"

    DISPLAY=":$XDISP" "$SWALLOW" --occupy --timeout 30 "$@" >/tmp/swallow-test-run.log 2>&1 &
    local swallow_pid=$!
    CLEANUP_PIDS+=("$swallow_pid")

    local app_win="" ticks=100 # real apps can be slower to start than xmessage
    while [ -z "$app_win" ] && [ "$ticks" -gt 0 ]; do
        app_win="$(find_window_by_class "$wm_class")"
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

    # Wider tolerance than the synthetic scenarios: real apps can enforce
    # their own minimum size (e.g. kate's sidebar/toolbar layout), which is
    # legitimate and outside swallow's control.
    verify_swallow_behavior "$desc" "$term_win" "$app_win" "$term_geom_before" "$swallow_pid" 60

    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

# --- scenario: --timeout gives up instead of hanging forever -------------
# `sleep` never creates a window at all. With --timeout 1, swallow should
# give up around then rather than blocking until sleep exits on its own --
# and, critically, without ever having hidden the terminal in the meantime.
run_timeout_scenario() {
    local desc="timeout"
    local term_title="SwallowTestTerm-$$-$RANDOM"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" term_geom_before="$SETUP_TERM_GEOM" xterm_pid="$SETUP_XTERM_PID"

    local start=$SECONDS
    DISPLAY=":$XDISP" "$SWALLOW" --timeout 1 sleep 5 >/tmp/swallow-test-timeout.log 2>&1
    local status=$? elapsed=$((SECONDS - start))

    if [ "$status" -ne 0 ]; then
        pass "$desc: swallow exits non-zero when no window ever appears"
    else
        fail "$desc: swallow exited 0 despite no window ever appearing"
    fi

    if [ "$elapsed" -le 4 ]; then
        pass "$desc: swallow gave up around --timeout instead of waiting for the command ($elapsed s)"
    else
        fail "$desc: swallow took ${elapsed}s to give up, expected ~1s (--timeout 1)"
    fi

    if window_mapped "$term_win"; then
        pass "$desc: terminal was never hidden after a timeout"
    else
        fail "$desc: terminal was hidden despite swallow timing out"
    fi

    if [ "$(window_geom "$term_win")" = "$term_geom_before" ]; then
        pass "$desc: terminal geometry untouched after a timeout"
    else
        fail "$desc: terminal geometry changed despite swallow timing out"
    fi

    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

# --- scenario: --remain, terminal takes the app's last spot on close -----
# Moves/resizes the app window after it appears (standing in for the user
# repositioning it while they work), then closes it and checks the terminal
# ends up there -- not back at its own original spot.
run_remain_scenario() {
    local desc="remain"
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local app_title="SwallowTestApp-$$-$RANDOM"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" term_geom_before="$SETUP_TERM_GEOM" xterm_pid="$SETUP_XTERM_PID"

    DISPLAY=":$XDISP" "$SWALLOW" --remain --timeout 30 xmessage -title "$app_title" -center "hello from $desc" \
        >/tmp/swallow-test-remain.log 2>&1 &
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

    local ticks=15
    while [ "$ticks" -gt 0 ]; do
        window_mapped "$term_win" || break
        ticks=$((ticks - 1))
        sleep 0.2
    done

    DISPLAY=":$XDISP" xdotool windowmove "$app_win" 120 90 >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool windowsize "$app_win" 260 180 >/dev/null 2>&1
    sleep 0.3
    local app_geom_final
    app_geom_final="$(window_geom "$app_win")"

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
    if geom_close "$term_geom_after" "$app_geom_final" 20; then
        pass "$desc: terminal took the app's last position/size ($term_geom_after ~ $app_geom_final)"
    else
        fail "$desc: terminal geometry ($term_geom_after) doesn't match app's last spot ($app_geom_final)"
    fi

    if [ "$term_geom_after" != "$term_geom_before" ]; then
        pass "$desc: terminal geometry differs from its original spot ($term_geom_before), as expected with --remain"
    else
        fail "$desc: terminal geometry unchanged from before ($term_geom_before) -- --remain had no effect"
    fi

    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

run_scenario "direct exec"
run_scenario "fork+exec launcher (double-fork daemonize style)" "$FORK_HELPER"
run_scenario "phantom helper window (Kate-style)" "$PHANTOM_HELPER"
run_detached_scenario
run_flags_scenario
run_timeout_scenario
run_remain_scenario

if command -v zathura >/dev/null 2>&1; then
    run_real_app_scenario "zathura (real app)" zathura zathura
else
    log "Scenario: zathura (real app) -- SKIPPED (zathura not installed)"
fi

if command -v kate >/dev/null 2>&1; then
    run_real_app_scenario "kate (real app)" kate kate
else
    log "Scenario: kate (real app) -- SKIPPED (kate not installed)"
fi

log ""
log "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
