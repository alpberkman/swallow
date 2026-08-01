#!/usr/bin/env bash
# Integration tests for swallow, run inside a throwaway Xephyr + openbox
# session so they don't touch the real desktop.
#
# Requires: Xephyr, openbox, xdotool, xprop. Skips (exit 0) if missing.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$ROOT_DIR/bin"
SWALLOW="$BIN_DIR/swallow"
FORK_HELPER="$BIN_DIR/fork_exec_helper"
PHANTOM_HELPER="$BIN_DIR/phantom_window_helper"
GEOM_TRACE_HELPER="$BIN_DIR/geom_trace_helper"
CREATE_TRACE_HELPER="$BIN_DIR/create_trace_helper"

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
[ -x "$GEOM_TRACE_HELPER" ] || { log "swallow tests: $GEOM_TRACE_HELPER not built"; exit 1; }
[ -x "$CREATE_TRACE_HELPER" ] || { log "swallow tests: $CREATE_TRACE_HELPER not built"; exit 1; }

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

    # --occupy determines the new window's full geometry itself, so
    # combining it with manual placement flags is rejected rather than
    # silently dropping the manual ones.
    if DISPLAY=":$XDISP" "$SWALLOW" --occupy -x 10 true >/dev/null 2>&1; then
        fail "flags: --occupy + -x should be rejected"
    else
        pass "flags: --occupy + -x is rejected"
    fi

    # Numeric flags must reject a non-numeric (or empty) argument outright,
    # not silently fall back to 0 -- regression test for -t/-x/-y/-w/-l all
    # sharing one strtol-based parser where an *empty* argument specifically
    # used to slip past the "did it fully parse" check (strtol sets endptr
    # to the input pointer itself on failure, which for "" already points at
    # the terminating '\0', so a bare `*end != '\0'` check missed it). Most
    # dangerous for -t: an unrejected empty argument silently became timeout
    # 0, i.e. "wait forever" -- wrapped in `timeout` here so a regression
    # fails fast instead of hanging the suite.
    if timeout 5 env DISPLAY=":$XDISP" "$SWALLOW" -t "" true >/dev/null 2>&1; then
        fail "flags: -t '' should be rejected"
    else
        pass "flags: -t '' is rejected (and doesn't hang)"
    fi

    if DISPLAY=":$XDISP" "$SWALLOW" -x "" true >/dev/null 2>&1; then
        fail "flags: -x '' should be rejected"
    else
        pass "flags: -x '' is rejected"
    fi

    if DISPLAY=":$XDISP" "$SWALLOW" -x abc true >/dev/null 2>&1; then
        fail "flags: -x abc should be rejected"
    else
        pass "flags: -x abc is rejected"
    fi

    # -w/-l specifically must also reject negative values (unlike -x/-y,
    # where negative is legitimate for multi-monitor setups extending
    # left/up of the primary).
    if DISPLAY=":$XDISP" "$SWALLOW" -w -5 true >/dev/null 2>&1; then
        fail "flags: negative -w should be rejected"
    else
        pass "flags: negative -w is rejected"
    fi

    if DISPLAY=":$XDISP" "$SWALLOW" -l -5 true >/dev/null 2>&1; then
        fail "flags: negative -l should be rejected"
    else
        pass "flags: negative -l is rejected"
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

# --- scenario: --kill closes the terminal instead of restoring it --------
run_kill_scenario() {
    local desc="kill"
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local app_title="SwallowTestApp-$$-$RANDOM"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" xterm_pid="$SETUP_XTERM_PID"

    DISPLAY=":$XDISP" "$SWALLOW" --kill --timeout 30 xmessage -title "$app_title" -center "hello from $desc" \
        >/tmp/swallow-test-kill.log 2>&1 &
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

    DISPLAY=":$XDISP" xdotool windowkill "$app_win" >/dev/null 2>&1

    if wait_for 10 bash -c "! kill -0 $swallow_pid 2>/dev/null"; then
        pass "$desc: swallow exited after app window closed"
    else
        fail "$desc: swallow did not exit after app window closed"
        kill "$swallow_pid" "$xterm_pid" >/dev/null 2>&1
        return
    fi

    if wait_for 10 bash -c "! kill -0 $xterm_pid 2>/dev/null"; then
        pass "$desc: terminal was closed instead of restored"
    else
        fail "$desc: terminal is still running after --kill"
        kill "$xterm_pid" >/dev/null 2>&1
    fi

    if [ -z "$(find_window "$term_title")" ]; then
        pass "$desc: terminal window no longer exists"
    else
        fail "$desc: terminal window still exists after --kill"
    fi

    wait "$xterm_pid" 2>/dev/null
}

# --- scenario: --remain restore must not flash through the old geometry --
# A before/after geometry check (like run_remain_scenario above) can't catch
# a WM (Openbox confirmed) briefly remapping the terminal at its old
# size/position before jumping to the correct one a few ms later -- both
# checks would still pass since they only look at the final state. Traces
# every ConfigureNotify the terminal gets during the restore (via
# geom_trace_helper, selected on it *before* the app window is closed so it
# can't miss anything) and fails if any of them still carries the terminal's
# original size -- that would mean the remap landed on the old geometry
# first, i.e. the flash regressed.
run_remain_flash_scenario() {
    local desc="remain flash"
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local app_title="SwallowTestApp-$$-$RANDOM"
    local trace_log="/tmp/swallow-test-remain-flash-$$.log"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" term_geom_before="$SETUP_TERM_GEOM" xterm_pid="$SETUP_XTERM_PID"
    local term_w_before term_h_before
    IFS=, read -r _ _ term_w_before term_h_before <<< "$term_geom_before"

    DISPLAY=":$XDISP" "$SWALLOW" --remain --timeout 30 xmessage -title "$app_title" -center "hello from $desc" \
        >/tmp/swallow-test-remain-flash-run.log 2>&1 &
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

    DISPLAY=":$XDISP" xdotool windowmove "$app_win" 150 110 >/dev/null 2>&1
    DISPLAY=":$XDISP" xdotool windowsize "$app_win" 240 160 >/dev/null 2>&1
    sleep 0.3

    DISPLAY=":$XDISP" "$GEOM_TRACE_HELPER" "$term_win" >"$trace_log" 2>&1 &
    local trace_pid=$!
    CLEANUP_PIDS+=("$trace_pid")
    sleep 0.3

    local app_pid
    app_pid="$(DISPLAY=":$XDISP" xdotool getwindowpid "$app_win" 2>/dev/null)"
    if [ -n "$app_pid" ]; then
        kill -TERM "$app_pid" >/dev/null 2>&1
    else
        DISPLAY=":$XDISP" xdotool windowkill "$app_win" >/dev/null 2>&1
    fi

    wait_for 10 bash -c "! kill -0 $swallow_pid 2>/dev/null" >/dev/null
    sleep 0.3
    kill "$trace_pid" >/dev/null 2>&1
    wait "$trace_pid" 2>/dev/null

    if grep -qx "${term_w_before},${term_h_before}" "$trace_log"; then
        fail "$desc: terminal briefly remapped at its old size ($term_w_before,$term_h_before) before correcting -- restore flash regressed"
    else
        pass "$desc: terminal never remapped at its old size during restore"
    fi

    rm -f "$trace_log"
    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

# --- scenario: --occupy must not flash the new window through its own
# default placement first --
# wait_for_target_window only returns once the target's MapNotify has
# already arrived, i.e. it's already visible on screen -- so a before/after
# geometry check alone (like run_scenario's) can't catch the WM (Openbox
# confirmed) briefly mapping it at its own default placement/size (e.g.
# xmessage's own natural button size, before growing to fill the occupy
# spot) before swallow's own post-map _NET_MOVERESIZE_WINDOW correction
# fixes it a moment later. Traces every ConfigureNotify the target gets (via
# create_trace_helper, started before swallow launches so it can't miss the
# window's creation) and fails if it was ever seen at more than one distinct
# real (not the 0,0/1,1 placeholder every window briefly has right after
# XCreateWindow) *size* -- more than one means it was visibly resized after
# already being on screen, i.e. a flash. Width/height rather than x/y,
# deliberately: like geom_trace_helper (see run_remain_flash_scenario),
# ConfigureNotify's x/y are relative to the window's *current* parent, and
# swallow's target here gets reparented into a WM frame partway through this
# trace -- comparing raw x/y across that boundary compares two different
# coordinate spaces and isn't meaningful, whereas width/height aren't
# affected by reparenting at all. Deliberately doesn't use -center on
# xmessage (unlike run_remain_flash_scenario): an app that explicitly
# repositions itself right before its own map is a known, inherent race no
# pre-map trick from a third process can reliably win -- this test is about
# the WM's own default placement, not that.
run_occupy_flash_scenario() {
    local desc="occupy flash"
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local app_title="SwallowTestApp-$$-$RANDOM"
    local trace_log="/tmp/swallow-test-occupy-flash-$$.log"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" xterm_pid="$SETUP_XTERM_PID"

    DISPLAY=":$XDISP" "$CREATE_TRACE_HELPER" >"$trace_log" 2>&1 &
    local trace_pid=$!
    CLEANUP_PIDS+=("$trace_pid")
    sleep 0.3

    DISPLAY=":$XDISP" "$SWALLOW" --occupy --timeout 30 xmessage -title "$app_title" "hello from $desc" \
        >/tmp/swallow-test-occupy-flash-run.log 2>&1 &
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
        kill "$swallow_pid" "$trace_pid" "$xterm_pid" >/dev/null 2>&1
        return
    fi
    sleep 0.3

    DISPLAY=":$XDISP" xdotool windowkill "$app_win" >/dev/null 2>&1
    wait_for 10 bash -c "! kill -0 $swallow_pid 2>/dev/null" >/dev/null
    sleep 0.3
    kill "$trace_pid" >/dev/null 2>&1
    wait "$trace_pid" 2>/dev/null

    local distinct
    distinct="$(awk -v id="$app_win" '
        $1 == "configure" && $2 == id {
            split($3, g, ",")
            if (g[3] > 1 && g[4] > 1) print g[3] "," g[4]
        }' "$trace_log" | sort -u | wc -l)"

    if [ "$distinct" -le 1 ]; then
        pass "$desc: app window never appeared at any size but the occupy spot's"
    else
        fail "$desc: app window was seen at $distinct different sizes before settling -- occupy flash regressed"
    fi

    rm -f "$trace_log"
    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

# --- scenario: --occupy must not flash through a real app's own pre-map
# resize --
# run_occupy_flash_scenario (above) uses xmessage, which turned out to never
# actually trigger this: it computes its size once, in XCreateWindow itself,
# with nothing afterward to race. Real toolkit apps (Qt/GTK -- zathura, kate,
# pcmanfm all confirmed via create_trace_helper) instead create small and
# then explicitly resize themselves to fit their content sometime between
# CreateNotify and their own XMapWindow -- landing after
# apply_pre_map_placement's XConfigureWindow and silently overriding it, so
# the window mapped at its own natural size (e.g. zathura's 800x600) first
# and only snapped to the requested spot an instant later. This is what
# apply_pre_map_placement's WM_NORMAL_HINTS PMinSize/PMaxSize pin (not just
# PSize) fixes, by making the WM clamp the app's own resize too, not just
# swallow's.
#
# Unlike run_occupy_flash_scenario, this doesn't fail on seeing more than one
# distinct pre-map size -- a real app's own pre-map churn (confirmed
# harmless: it's still invisible, since the window isn't mapped yet) is
# expected and fine. What matters is whether the size it's *actually mapped
# at* already matches the size it settles at afterward -- if those differ,
# the window was visibly resized after already being on screen, i.e. a real
# flash. Optional: skipped if the given app isn't installed.
run_real_app_occupy_flash_scenario() {
    local desc="$1" wm_class="$2"; shift 2
    local term_title="SwallowTestTerm-$$-$RANDOM"
    local trace_log="/tmp/swallow-test-real-flash-$$.log"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" xterm_pid="$SETUP_XTERM_PID"

    DISPLAY=":$XDISP" "$CREATE_TRACE_HELPER" >"$trace_log" 2>&1 &
    local trace_pid=$!
    CLEANUP_PIDS+=("$trace_pid")
    sleep 0.3

    DISPLAY=":$XDISP" "$SWALLOW" --occupy --timeout 30 "$@" \
        >/tmp/swallow-test-real-flash-run.log 2>&1 &
    local swallow_pid=$!
    CLEANUP_PIDS+=("$swallow_pid")

    local app_win="" ticks=100
    while [ -z "$app_win" ] && [ "$ticks" -gt 0 ]; do
        app_win="$(find_window_by_class "$wm_class")"
        [ -n "$app_win" ] && break
        ticks=$((ticks - 1))
        sleep 0.2
    done
    if [ -z "$app_win" ]; then
        fail "$desc: app window never appeared"
        kill "$swallow_pid" "$trace_pid" "$xterm_pid" >/dev/null 2>&1
        rm -f "$trace_log"
        return
    fi
    sleep 0.5

    DISPLAY=":$XDISP" xdotool windowkill "$app_win" >/dev/null 2>&1
    wait_for 10 bash -c "! kill -0 $swallow_pid 2>/dev/null" >/dev/null
    sleep 0.3
    kill "$trace_pid" >/dev/null 2>&1
    wait "$trace_pid" 2>/dev/null

    local sizes
    sizes="$(awk -v id="$app_win" '
        $1 == "configure" && $2 == id {
            split($3, g, ",")
            if (g[3] > 1 && g[4] > 1) {
                last = g[3] "," g[4]
                if (!mapped) at_map = last
            }
        }
        $1 == "map" && $2 == id { mapped = 1; at_map = last }
        END { print at_map, last }
    ' "$trace_log")"
    local size_at_map size_final
    size_at_map="$(echo "$sizes" | cut -d' ' -f1)"
    size_final="$(echo "$sizes" | cut -d' ' -f2)"

    if [ -n "$size_at_map" ] && [ "$size_at_map" = "$size_final" ]; then
        pass "$desc: app window was already at its final size ($size_at_map) when mapped"
    else
        fail "$desc: app window was mapped at $size_at_map but settled at $size_final -- occupy flash regressed"
    fi

    rm -f "$trace_log"
    kill "$xterm_pid" >/dev/null 2>&1
    wait "$xterm_pid" 2>/dev/null
}

# --- scenario: --help is pipeable/pageable (goes to stdout, not stderr) ----
# usage()/--help used to always go to stderr, indistinguishable from a usage
# error and unusable with `swallow --help | less`. Checks the help text
# lands on stdout specifically, and that stderr is empty for this
# unambiguously-successful invocation.
run_help_stdout_scenario() {
    log "Scenario: --help output stream"

    local stdout_out stderr_out status
    stdout_out="$(DISPLAY=":$XDISP" "$SWALLOW" --help 2>/tmp/swallow-test-help-stderr.log)"
    status=$?
    stderr_out="$(cat /tmp/swallow-test-help-stderr.log)"
    rm -f /tmp/swallow-test-help-stderr.log

    if [ "$status" -eq 0 ]; then
        pass "--help: exits 0"
    else
        fail "--help: exited $status, expected 0"
    fi

    if echo "$stdout_out" | grep -q -- '--occupy' && echo "$stdout_out" | grep -q -- '--remain'; then
        pass "--help: full help text is on stdout"
    else
        fail "--help: help text missing from stdout"
    fi

    if [ -z "$stderr_out" ]; then
        pass "--help: stderr is empty"
    else
        fail "--help: unexpected stderr output: $stderr_out"
    fi
}

# --- scenario: a command that doesn't even exist behaves like a timeout ----
# run_timeout_scenario covers a command that runs but never opens a window
# (sleep); this covers execvp() itself failing (typo'd/missing binary) --
# the fork'd child prints an error and _exit(127)s immediately, and
# wait_for_target_window has no way to know that happened (it only watches
# for X events), so swallow must still just run out its --timeout and exit
# non-zero rather than, say, hanging or crashing on the dead child.
run_bad_command_scenario() {
    local desc="nonexistent command"
    local term_title="SwallowTestTerm-$$-$RANDOM"

    log "Scenario: $desc"

    setup_terminal "$desc" "$term_title" || return
    local term_win="$SETUP_TERM_WIN" term_geom_before="$SETUP_TERM_GEOM" xterm_pid="$SETUP_XTERM_PID"

    local start=$SECONDS
    DISPLAY=":$XDISP" "$SWALLOW" --timeout 2 /no/such/binary-swallow-test-$$ \
        >/tmp/swallow-test-badcmd.log 2>&1
    local status=$? elapsed=$((SECONDS - start))

    if [ "$status" -ne 0 ]; then
        pass "$desc: swallow exits non-zero"
    else
        fail "$desc: swallow exited 0 despite the command never existing"
    fi

    if [ "$elapsed" -le 5 ]; then
        pass "$desc: swallow gave up around --timeout instead of hanging ($elapsed s)"
    else
        fail "$desc: swallow took ${elapsed}s to give up, expected ~2s (--timeout 2)"
    fi

    if window_mapped "$term_win" && [ "$(window_geom "$term_win")" = "$term_geom_before" ]; then
        pass "$desc: terminal was never touched"
    else
        fail "$desc: terminal was hidden or moved despite the command never existing"
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
run_kill_scenario
run_remain_flash_scenario
run_occupy_flash_scenario
run_help_stdout_scenario
run_bad_command_scenario

if command -v zathura >/dev/null 2>&1; then
    run_real_app_scenario "zathura (real app)" zathura zathura
    run_real_app_occupy_flash_scenario "zathura occupy flash (real app)" zathura zathura
else
    log "Scenario: zathura (real app) -- SKIPPED (zathura not installed)"
    log "Scenario: zathura occupy flash (real app) -- SKIPPED (zathura not installed)"
fi

if command -v kate >/dev/null 2>&1; then
    run_real_app_scenario "kate (real app)" kate kate
    run_real_app_occupy_flash_scenario "kate occupy flash (real app)" kate kate
else
    log "Scenario: kate (real app) -- SKIPPED (kate not installed)"
    log "Scenario: kate occupy flash (real app) -- SKIPPED (kate not installed)"
fi

log ""
log "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
