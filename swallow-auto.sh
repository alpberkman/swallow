#!/bin/bash
# swallow-auto.sh: picks the right swallow implementation for whatever WM
# is currently running, so callers (shell-integration.sh, a keybinding,
# etc) don't need WM-specific logic of their own.
#
# - i3/sway: swallow-i3.sh -- it needs their IPC anyway, and gets extra
#   scratchpad/tiling behavior that only that IPC can provide.
# - anything else (Openbox, etc): swallow, the plain X11 binary.
#
# Args are passed straight through to swallow -- it's the one that
# understands its own flags. swallow-i3.sh has none of its own (its
# behavior is fixed) and would misread a leading "--occupy" or "--remain"
# as the command to run, so those are stripped first when it's the one
# being dispatched to -- see strip_swallow_flags below. This is what lets
# one caller (e.g. shell-integration.sh) use the same invocation
# regardless of which WM ends up handling it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer the installed names on $PATH (what `make install` puts in
# $PREFIX/bin, e.g. ~/.local/bin) over the repo-relative dev paths --
# once installed, this script no longer sits next to bin/swallow or
# swallow-i3/swallow-i3.sh, so SCRIPT_DIR-relative lookups alone would
# break for an installed copy. Falls back to the repo layout so this
# still works run straight out of a checkout, unbuilt-into-PATH.
if command -v swallow-i3 >/dev/null 2>&1; then
    SWALLOW_I3=swallow-i3
else
    SWALLOW_I3="$SCRIPT_DIR/swallow-i3/swallow-i3.sh"
fi
if command -v swallow >/dev/null 2>&1; then
    SWALLOW_BIN=swallow
else
    SWALLOW_BIN="$SCRIPT_DIR/bin/swallow"
fi

# List kept in sync with `bin/swallow --help`. is_value_flag marks the
# ones that consume a following arg (-x 10, not just -x).
is_swallow_flag() {
    case "$1" in
        -x|--x|-y|--y|-w|--width|-l|--length|-d|--default|-o|--occupy| \
        -f|--full-screen|-t|--timeout|-r|--remain|-h|--help) return 0 ;;
        *) return 1 ;;
    esac
}
is_value_flag() {
    case "$1" in
        -x|--x|-y|--y|-w|--width|-l|--length|-t|--timeout) return 0 ;;
        *) return 1 ;;
    esac
}

strip_swallow_flags() {
    while [ "$#" -gt 0 ] && is_swallow_flag "$1"; do
        if is_value_flag "$1"; then shift 2; else shift; fi
    done
    printf '%s\0' "$@"
}

# $SWAYSOCK is set by sway itself (never by i3); a live `i3-msg -t
# get_version` is what actually confirms i3 is running, rather than just
# i3-msg being present on PATH -- otherwise this would pick swallow-i3.sh
# under a WM that merely has i3-msg installed but isn't running, only to
# have it fail later trying to reach a socket that isn't there.
#
# $I3SOCK is deliberately unset (in a subshell, so it's not lost for
# anything after this check) before that call: if it's set in the
# environment -- which it normally is, session-wide, wherever a real i3 is
# running -- i3-msg uses it directly and never looks at $DISPLAY at all.
# That means a nested Xephyr+Openbox test session run from inside a real
# i3 session would still find that outer i3 reachable and wrongly conclude
# i3 owns the *current* display. Unsetting it forces i3-msg's own X-atom
# auto-discovery (the I3_SOCKET_PATH property on $DISPLAY's root window),
# which is actually scoped to the display this process is talking to.
if [ -n "${SWAYSOCK:-}" ] || { command -v i3-msg >/dev/null 2>&1 && ( unset I3SOCK; i3-msg -t get_version >/dev/null 2>&1 ); }; then
    args=()
    while IFS= read -r -d '' a; do args+=("$a"); done < <(strip_swallow_flags "$@")
    exec "$SWALLOW_I3" "${args[@]}"
else
    exec "$SWALLOW_BIN" "$@"
fi
