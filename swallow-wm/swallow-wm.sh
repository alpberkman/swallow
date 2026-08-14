#!/bin/bash
# This script starts a throwaway Xephyr session. It runs mwm inside it.
set -eu

# cd "$(dirname "${BASH_SOURCE[0]}")"

HOST_DISPLAY="$DISPLAY"

FIFO=$(mktemp -u);
mkfifo "$FIFO"

# Clean up on exit.
trap 'kill "$XEPHYR_PID" "$WM_PID" "$APP_PID" "$CLIP_PID" 2>/dev/null' EXIT

# -displayfd picks a free display number by itself. It writes the number
# to fd 3. It writes only once Xephyr is ready to accept connections.
# This is a true readiness signal. It is not a sleep. It is not a poll
# loop.

# Start Xephyr.
Xephyr -displayfd 3 -screen 1024x768 -resizeable -no-host-grab 3>"$FIFO" & XEPHYR_PID=$!

# Read the display number.
export DISPLAY=":$(cat "$FIFO")"
rm -f "$FIFO"

# Start the WM.
mwm & WM_PID=$!

# Xephyr is a separate X server. It has its own clipboard, with no link
# to the host's. This loop bridges the two CLIPBOARD selections. There
# is no cross-display clipboard-change event to hook, so this has to
# poll.
(
    last=""
    while true; do
        h=$(DISPLAY="$HOST_DISPLAY" xclip -selection clipboard -o 2>/dev/null || true)
        x=$(xclip -selection clipboard -o 2>/dev/null || true)
        if [ "$h" != "$last" ] && [ "$h" != "$x" ]; then
            printf '%s' "$h" | xclip -selection clipboard -i
            last="$h"
        elif [ "$x" != "$last" ]; then
            printf '%s' "$x" | DISPLAY="$HOST_DISPLAY" xclip -selection clipboard -i
            last="$x"
        fi
        sleep 1
    done
) & CLIP_PID=$!

# Mark this session as running inside swallow-wm. swallow-auto.sh
# checks this to skip its own hide-and-restore job: mwm already fills
# the screen with one window at a time, so there is nothing to swallow.
export SWALLOW_WM=1

# Start the app.
"$@" & APP_PID=$!

# Wait for the first of the three to stop: Xephyr, mwm, or the app. The
# clipboard loop is not in this list; it runs until killed by the trap.
wait -n "$XEPHYR_PID" "$WM_PID" "$APP_PID"
