#!/bin/bash
# swallow-auto.sh: picks the right swallow implementation for whatever WM
# is currently running, so callers (shell-integration.sh, a keybinding,
# etc) don't need WM-specific logic of their own.
#
# - i3/sway: swallow-i3/swallow-i3.sh -- it needs their IPC anyway, and
#   gets extra scratchpad/tiling behavior that only that IPC can provide.
# - anything else (Openbox, etc): bin/swallow, the plain X11 binary.
#
# Args are passed straight through to whichever one is picked. swallow's
# own CLI flags (-o/-r/-t/etc) only mean anything to the X11 binary --
# swallow-i3.sh has none of its own (its behavior is fixed), so passing
# them through under i3/sway is the caller's responsibility, same as
# calling swallow-i3.sh directly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# $SWAYSOCK is set by sway itself (never by i3); a live `i3-msg -t
# get_version` is what actually confirms i3 is running, rather than just
# i3-msg being present on PATH -- otherwise this would pick swallow-i3.sh
# under a WM that merely has i3-msg installed but isn't running, only to
# have it fail later trying to reach a socket that isn't there.
if [ -n "${SWAYSOCK:-}" ] || { command -v i3-msg >/dev/null 2>&1 && i3-msg -t get_version >/dev/null 2>&1; }; then
    exec "$SCRIPT_DIR/swallow-i3/swallow-i3.sh" "$@"
else
    exec "$SCRIPT_DIR/bin/swallow" "$@"
fi
