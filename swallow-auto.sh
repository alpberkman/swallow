#!/bin/bash
# Picks the right swallow implementation for the running window
# manager: swallow-i3.sh for i3/sway, else swallow-generic. Strips
# geometry/-d flags before dispatching to swallow-i3.sh, since it does
# not understand them; see strip_swallow_flags below.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer the installed names on $PATH; fall back to repo-relative paths
# for an unbuilt-into-PATH checkout. Checks swallow-generic, not
# swallow: this script is itself installed as `swallow`.
if command -v swallow-i3 >/dev/null 2>&1; then
    SWALLOW_I3=swallow-i3
else
    SWALLOW_I3="$SCRIPT_DIR/swallow-i3/swallow-i3.sh"
fi
if command -v swallow-generic >/dev/null 2>&1; then
    SWALLOW_BIN=swallow-generic
else
    SWALLOW_BIN="$SCRIPT_DIR/bin/swallow-generic"
fi

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
if [ -n "${SWAYSOCK:-}" ] || { command -v i3-msg >/dev/null 2>&1 && ( unset I3SOCK; i3-msg -t get_version >/dev/null 2>&1 ); }; then
    args=()
    while IFS= read -r -d '' a; do args+=("$a"); done < <(strip_swallow_flags "$@")
    exec "$SWALLOW_I3" "${args[@]}"
else
    exec "$SWALLOW_BIN" "$@"
fi
