#!/bin/bash
# Picks the right swallow implementation for the running window
# manager: swallow-i3.sh for i3/sway, else swallow-generic. Strips
# geometry/-d flags before dispatching to swallow-i3.sh, since it does
# not understand them; see strip_swallow_flags below.
set -u

# Kept in sync with `bin/swallow-generic --help`. is_value_flag marks
# flags that take a following arg (-x 10, not just -x).
is_swallow_flag() {
    case "$1" in
        -x|--x|-y|--y|-w|--width|-l|--length|-d|--default|-o|--occupy| \
        -f|--full-screen|-t|--timeout|-r|--remain|-k|--kill|-h|--help) return 0 ;;
        *) return 1 ;;
    esac
}
is_value_flag() {
    case "$1" in
        -x|--x|-y|--y|-w|--width|-l|--length|-t|--timeout) return 0 ;;
        *) return 1 ;;
    esac
}

# swallow-wm.sh sets this inside its nested session. mwm already fills
# the screen with one window at a time, so there is no terminal to
# hide or restore. Strip swallow's own flags, since callers such as
# shell-integration.sh still pass them, then run the bare command.
if [ -n "${SWALLOW_WM:-}" ]; then
    while [ "$#" -gt 0 ] && is_swallow_flag "$1"; do
        if is_value_flag "$1"; then
            shift 2
        else
            shift
        fi
    done
    exec "$@"
    echo "Hello from swallow wm!"
    exit 127
fi

# swallow-i3.sh's own subset of is_swallow_flag; passed through, not
# stripped, when dispatching to it.
is_i3_flag() {
    case "$1" in
        -k|--kill|-f|--full-screen|-o|--occupy|-r|--remain|-t|--timeout|-h|--help) return 0 ;;
        *) return 1 ;;
    esac
}

strip_swallow_flags() {
    kept=()
    while [ "$#" -gt 0 ] && is_swallow_flag "$1"; do
        if is_i3_flag "$1"; then
            kept+=("$1")
            shift
        elif is_value_flag "$1"; then
            shift 2
        else
            shift
        fi
    done
    printf '%s\0' "${kept[@]}" "$@"
}

# $SWAYSOCK is set only by sway. A live `i3-msg -t get_version` confirms
# i3 is actually running, not just installed. $I3SOCK is unset first (in
# a subshell): if set, i3-msg uses it and ignores $DISPLAY, so a nested
# test session could wrongly see an outer, real i3 as owning it.
is_i3_running() {
    command -v i3-msg >/dev/null 2>&1 && ( unset I3SOCK; i3-msg -t get_version >/dev/null 2>&1 )
}

if [ -n "${SWAYSOCK:-}" ] || is_i3_running; then
    args=()
    while IFS= read -r -d '' a; do args+=("$a"); done < <(strip_swallow_flags "$@")
    exec swallow-i3 "${args[@]}"
else
    exec swallow-generic "$@"
fi
