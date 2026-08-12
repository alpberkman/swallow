#!/bin/bash
# swallow-i3.sh hides the terminal window. The terminal starts the
# command. When the new window opens, swallow-i3.sh hides the terminal.
# When the new window closes, swallow-i3.sh shows the terminal again and
# gives it focus.
#
# --occupy makes the new window take the terminal's exact spot. If the
# terminal was floating, the script moves the new window to a floating
# position, using the terminal's old position and size. i3 does not give
# this floating state to new windows on its own. If the terminal was
# tiled, the script sets the new window to the terminal's exact tiled
# size. i3 does not always do this step on its own. See the "new" event
# handler below for the code. Without --occupy, the new window is placed
# however i3's own default policy would place it.
#
# --remain restores the terminal to wherever the app's window ended up,
# instead of the terminal's original position/size -- for example if the
# user moved or resized the app window while it was open. Without
# --remain, the terminal returns to its original spot.
#
# i3-msg sends the IPC commands. jq reads the JSON output. This script
# does not parse the socket data by hand.
#
# This script also works under sway. Sway uses the same IPC protocol and
# the same commands: get_tree, window subscribe, scratchpad, floating,
# move, and resize. Every command below works on both programs without
# change. See the swaymsg/i3-msg check below.
set -u

TIMEOUT=3
KILL=0
FULLSCREEN=0
OCCUPY=0
REMAIN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -k|--kill) KILL=1; shift ;;
    -f|--full-screen) FULLSCREEN=1; shift ;;
    -o|--occupy) OCCUPY=1; shift ;;
    -r|--remain) REMAIN=1; shift ;;
    -t|--timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -*|--*) echo "swallow-i3: unknown flag: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "swallow-i3: --timeout requires a numeric value" >&2
  exit 1
fi

if [ "$#" -lt 1 ]; then
  echo "usage: $0 [-k|--kill] [-f|--full-screen] [-o|--occupy] [-r|--remain] [-t|--timeout <seconds>] <command> [args...]" >&2
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "swallow-i3: jq not found" >&2
  exit 1
fi

if [ -n "${I3SOCK:-}" ] && command -v i3-msg >/dev/null; then
  msg=i3-msg
elif [ -n "${SWAYSOCK:-}" ] && command -v swaymsg >/dev/null; then
  msg=swaymsg
else
  echo "swallow-i3: neither i3-msg nor swaymsg are found" >&2
  exit 1
fi

term=$("$msg" -t get_tree |
  jq -r 'first(.. | objects | select(.focused).window) // empty')
if [ -z "$term" ] || [ "$term" = "null" ]; then
  echo "swallow-i3: could not determine terminal window" >&2
  exit 1
fi

# Record the terminal's floating state and rectangle now, before any window moves.
read -r t_floating tx ty tw th < <(
  "$msg" -t get_tree | jq -r --argjson w "$term" '
    first(.. | objects | select(.window? == $w)) |
    "\(if .floating | IN("user_on", "auto_on") then 1 else 0 end) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"'
)

# Subscribe to window events before you start the command. This way, the
# script cannot miss the "new window" event from the command.
exec 3< <("$msg" -t subscribe -m '["window"]')

have_app=0
app_win=""
w_floating=""
w_x=""
w_y=""
w_w=""
w_h=""

# The "scratchpad show" command always makes a window float. This is
# normal i3 behavior. i3 does not undo this by itself.
#
# To fix this: if the window was floating before, set its old rectangle
# again. If the window was tiled before, turn off floating so the window
# tiles again.
restore_term() {
  local floating=$1 x=$2 y=$3 w=$4 h=$5
  "$msg" "[id=\"$term\"] scratchpad show" >/dev/null
  if [ "$floating" = 1 ]; then
    "$msg" "[id=\"$term\"] move position $x $y, resize set $w $h" >/dev/null
  else
    "$msg" "[id=\"$term\"] floating disable" >/dev/null
    "$msg" "[id=\"$term\"] resize set $w $h" >/dev/null 2>/dev/null
  fi
}

# With --kill, close the terminal with i3's own "kill" command instead
# of restoring it. This is the IPC form of swallow's close_window()
# function, which uses WM_DELETE_WINDOW and XKillClient.
#
# With --remain, uses the app's last-known rectangle (w_floating/w_x/...,
# set by the close-event handler below) instead of the terminal's own
# original rectangle -- so a resize made while the app was open stays in
# effect.
finish_term() {
  if [ "$KILL" = 1 ]; then
    "$msg" "[id=\"$term\"] kill" >/dev/null
  elif [ "$REMAIN" = 1 ]; then
    restore_term "$w_floating" "$w_x" "$w_y" "$w_w" "$w_h"
  else
    restore_term "$t_floating" "$tx" "$ty" "$tw" "$th"
  fi
}

trap finish_term INT TERM

"$@" &
child_pid=$!
child_running=1
exit_time=0

buf=""
while true; do
  # `read -t` can time out in the middle of a line during a slow event.
  # Keep the partial data in `buf` instead of dropping it. If you drop
  # it, jq later gets a broken JSON line.
  if IFS= read -r -t 0.5 -u 3 chunk; then
    line="$buf$chunk"
    buf=""
    IFS=$'\t' read -r change win <<<"$(jq -r '[.change, (.container.window // "")] | @tsv' <<<"$line")"
    if [ "$have_app" = 0 ] && [ "$change" = new ] && [ -n "$win" ] && [ "$win" != "$term" ]; then
      app_win=$win
      have_app=1
      "$msg" "[id=\"$term\"] move scratchpad" >/dev/null
      if [ "$OCCUPY" = 1 ]; then
        # Do not rely on i3's own split-and-reflow step to give the
        # new window the terminal's old size after the terminal
        # leaves for the scratchpad. This step does not always work,
        # because of default split ratios, size hints, or timing. So
        # set the size directly here, the same way restore_term sets
        # it directly later.
        if [ "$t_floating" = 1 ]; then
          "$msg" "[id=\"$app_win\"] floating enable, move position $tx $ty, resize set $tw $th" >/dev/null
        else
          "$msg" "[id=\"$app_win\"] resize set $tw $th" >/dev/null 2>/dev/null
        fi
      fi
      # i3 remembers the rectangle set above. Turning off fullscreen later returns to it.
      [ "$FULLSCREEN" = 1 ] && "$msg" "[id=\"$app_win\"] fullscreen enable" >/dev/null
    elif [ "$have_app" = 1 ] && [ "$change" = close ] && [ "$win" = "$app_win" ]; then
      # The close event itself carries the app's rectangle and
      # floating state at the time of closing. With --remain,
      # finish_term uses this instead of the terminal's original
      # data, so a resize made while the app was open stays in effect.
      if [ "$REMAIN" = 1 ]; then
        read -r w_floating w_x w_y w_w w_h < <(
          jq -r '.container | "\(if .floating=="user_on" or .floating=="auto_on" then 1 else 0 end) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"' <<<"$line"
        )
      fi
      finish_term
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
    [ $(($(date +%s) - exit_time)) -ge "$TIMEOUT" ]; then
    # No matching window showed up. Possible causes: a typo, a
    # command-line-only program, or a program that gave up. Stop waiting.
    exit 0
  fi
done
