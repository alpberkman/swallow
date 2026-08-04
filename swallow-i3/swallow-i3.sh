#!/bin/bash
# swallow-i3.sh: hide the launching i3 terminal while the launched
# command's window is open, restore + refocus it on close. If the terminal
# was floating, the new window is forced into floating mode at the
# terminal's rect (i3 doesn't inherit floating state for newly-spawned
# windows); if it was tiled, the new window is instead force-resized to
# the terminal's exact tiled size (i3's own reflow doesn't reliably land
# it there on its own -- see the "new" event handler below). i3-msg
# handles the IPC protocol and jq handles the JSON, so there's no
# hand-rolled socket framing or brace-matching here.
#
# Also works under sway: sway implements the same IPC protocol and command
# language (get_tree, window subscribe, scratchpad, floating, move/resize),
# so every command below runs unmodified against either compositor -- see
# the swaymsg/i3-msg selection right below.
set -u

GRACE=10 # seconds to wait for a window after the launched process exits

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 1
fi
command -v jq >/dev/null || { echo "swallow-i3: jq not found" >&2; exit 1; }

# $SWAYSOCK is set by sway itself (never by i3), so its presence is what
# tells the two apart -- prefer swaymsg in that case, else fall back to
# i3-msg. Everything past this point goes through $msg instead of calling
# either binary by name.
if [ -n "${SWAYSOCK:-}" ] && command -v swaymsg >/dev/null; then
    msg=swaymsg
else
    command -v i3-msg >/dev/null || { echo "swallow-i3: i3-msg not found" >&2; exit 1; }
    msg=i3-msg
fi

term="${WINDOWID:-}"
[[ "$term" =~ ^[0-9]+$ ]] || term="" # reject anything but a plain decimal id
if [ -z "$term" ]; then
    term=$("$msg" -t get_tree |
        jq -r '[.. | objects | select(.focused == true) | .window // empty][0] // empty')
fi
if [ -z "$term" ] || [ "$term" = "null" ]; then
    echo "swallow-i3: could not determine terminal window" >&2
    exit 1
fi

# Capture floating state + rect before anything moves.
read -r t_floating tx ty tw th < <(
    "$msg" -t get_tree | jq -r --argjson w "$term" '
        [.. | objects | select(.window? == $w)][0] |
        "\(if .floating=="user_on" or .floating=="auto_on" then 1 else 0 end) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"'
)

# Subscribe before forking, so we can't miss the child's "new" event.
exec 3< <("$msg" -t subscribe -m '["window"]')

have_app=0
app_win=""

# "scratchpad show" always leaves a window floating -- that's inherent to
# how i3's scratchpad works, not something it undoes on its own. Correct for
# it: re-apply the given rect if it was floating, or disable floating so it
# re-tiles if it wasn't. Either way, also re-apply the width/height: a
# re-tiled window otherwise keeps whatever size i3's default split gave it
# in its new container -- position isn't meaningful for a tiled window (the
# layout decides that), but "resize set" still works to reclaim the size.
# Takes the rect explicitly (rather than always reading $t_floating/$tx/...)
# because on a normal close it's the app's own last-known rect that should
# be restored, not the terminal's from before launch -- if the app was
# resized while open, the terminal should come back at that size. Only the
# signal-handler path (app still open, no close event to read a rect from)
# falls back to the terminal's original capture.
restore_term() {
    local floating=$1 x=$2 y=$3 w=$4 h=$5
    "$msg" "[id=\"$term\"] scratchpad show" >/dev/null
    if [ "$floating" = 1 ]; then
        "$msg" "[id=\"$term\"] move position $x $y, resize set $w $h" >/dev/null
    else
        "$msg" "[id=\"$term\"] floating disable" >/dev/null
        # Fails harmlessly (and noisily) if the terminal ends up as the sole
        # window in its container -- there's nothing to trade space with,
        # but i3 already gives a solo window the full container by default.
        "$msg" "[id=\"$term\"] resize set $w $h" >/dev/null 2>/dev/null
    fi
}

restore_and_exit() {
    [ "$have_app" = 1 ] && restore_term "$t_floating" "$tx" "$ty" "$tw" "$th"
    exit 0
}
trap restore_and_exit INT TERM

"$@" &
child_pid=$!
child_running=1
exit_time=0

buf=""
while true; do
    # `read -t` can time out mid-line on a large/slow event; bash still
    # consumes what it read so far into $chunk but the `if` only fires on a
    # full line, so a naive version here would silently drop that fragment
    # -- the next successful read then gets fed only the *tail* of the same
    # JSON line, and jq chokes on it. Buffer across timeouts instead of
    # discarding, so a line split across polls is reassembled correctly.
    if IFS= read -r -t 0.5 -u 3 chunk; then
        line="$buf$chunk"
        buf=""
        IFS=$'\t' read -r change win <<<"$(jq -r '[.change, (.container.window // "")] | @tsv' <<<"$line")"
        if [ "$have_app" = 0 ] && [ "$change" = new ] && [ -n "$win" ] && [ "$win" != "$term" ]; then
            app_win=$win
            have_app=1
            "$msg" "[id=\"$term\"] move scratchpad" >/dev/null
            # Don't rely on i3's split-then-reflow to land the app on the
            # terminal's exact former size once term leaves for the
            # scratchpad -- in practice it doesn't always land there
            # (default split ratios, size hints, timing), so force it
            # explicitly, the same way restore_term forces it back.
            if [ "$t_floating" = 1 ]; then
                "$msg" "[id=\"$app_win\"] floating enable, move position $tx $ty, resize set $tw $th" >/dev/null
            else
                "$msg" "[id=\"$app_win\"] resize set $tw $th" >/dev/null 2>/dev/null
            fi
        elif [ "$have_app" = 1 ] && [ "$change" = close ] && [ "$win" = "$app_win" ]; then
            # The close event's own payload carries the app's rect/floating
            # as of closing -- use that instead of the terminal's original
            # capture, so a resize done while the app was open sticks.
            read -r a_floating ax ay aw ah < <(
                jq -r '.container | "\(if .floating=="user_on" or .floating=="auto_on" then 1 else 0 end) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"' <<<"$line"
            )
            restore_term "${a_floating:-$t_floating}" "${ax:-$tx}" "${ay:-$ty}" "${aw:-$tw}" "${ah:-$th}"
            exit 0
        fi
    else
        buf+="$chunk"
    fi

    if [ "$child_running" = 1 ] && ! kill -0 "$child_pid" 2>/dev/null; then
        child_running=0
        exit_time=$(date +%s)
    fi
    if [ "$have_app" = 0 ] && [ "$child_running" = 0 ] &&
        [ $(($(date +%s) - exit_time)) -ge "$GRACE" ]; then
        # Nothing that looks like its window ever showed up (typo,
        # CLI-only command, or the app gave up); stop waiting.
        exit 0
    fi
done
