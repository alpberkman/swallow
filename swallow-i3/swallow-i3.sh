#!/bin/bash
# This script hides the terminal while the launched command's window is
# open, and shows the terminal again when that window closes.
#
# The --occupy option puts the new window in the terminal's old spot,
# floating or tiled to match. i3 does not do this step by itself.
#
# The --remain option restores the terminal to the app window's last
# position instead of the terminal's own original spot.
#
# i3-msg sends the IPC commands. jq reads the JSON output.
#
# This script also works with sway (see the swaymsg/i3-msg check
# below): both use the same IPC commands.
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
    -h|--help)
      echo "usage: $0 [-k|--kill] [-f|--full-screen] [-o|--occupy] [-r|--remain] [-t|--timeout <seconds>] <command> [args...]"
      exit 0
      ;;
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

term=$("$msg" -t get_tree | jq -r 'first(.. | objects | select(.focused).window) // empty')

if [ -z "$term" ] || [ "$term" = "null" ]; then
  echo "swallow-i3: could not determine terminal window" >&2
  exit 1
fi

# Record the floating state and rectangle of the terminal now. Do this
# before any window moves.
read -r t_floating tx ty tw th < <(
  "$msg" -t get_tree | jq -r --argjson w "$term" '
    first(.. | objects | select(.window? == $w)) |
    "\(if .floating | IN("user_on", "auto_on") then 1 else 0 end) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"'
)

# Subscribe to window events before you start the command. If you do
# this, the script does not miss the "new window" event from the
# command.
exec 3< <("$msg" -t subscribe -m '["window"]' 2>/dev/null)

app_win=none
w_floating=""
w_x=""
w_y=""
w_w=""
w_h=""

place_window() {
  local win=$1 floating=$2 x=$3 y=$4 w=$5 h=$6
  if [ "$floating" = 1 ]; then
    "$msg" "[id=\"$win\"] floating enable, move position $x $y, resize set $w $h" &>/dev/null
  else
    "$msg" "[id=\"$win\"] floating disable" &>/dev/null
    "$msg" "[id=\"$win\"] resize set $w $h" &>/dev/null
  fi
}

cleanup() {
  if [ "$KILL" = 1 ]; then
    "$msg" "[id=\"$term\"] kill" &>/dev/null
    exit 0
  fi

  "$msg" "[id=\"$term\"] scratchpad show" &>/dev/null
  if [ "$REMAIN" = 1 ]; then
    place_window "$term" "$w_floating" "$w_x" "$w_y" "$w_w" "$w_h"
  else
    place_window "$term" "$t_floating" "$tx" "$ty" "$tw" "$th"
  fi
  exit 0
}

# Run cleanup on Ctrl-C or a normal kill
trap cleanup INT TERM

# Start the application using the rest of the arguments
"$@" &
start_time=$(date +%s)

buf=""
while true; do
  # The read -t command can time out in the middle of a line during a
  # slow event. Keep the partial data in buf. 
  if IFS= read -r -t 0.5 -u 3 chunk; then
    line="$buf$chunk"
    buf=""
    IFS=$'\t' read -r change win <<<"$(jq -r '[.change, (.container.window // "")] | @tsv' <<<"$line")"
    if [ "$app_win" = none ] && [ "$change" = new ] && [ -n "$win" ] && [ "$win" != "$term" ]; then
      # Register the first new window as our window
      app_win=$win
      "$msg" "[id=\"$term\"] move scratchpad" &>/dev/null
      [ "$OCCUPY" = 1 ] && place_window "$app_win" "$t_floating" "$tx" "$ty" "$tw" "$th"
      [ "$FULLSCREEN" = 1 ] && "$msg" "[id=\"$app_win\"] fullscreen enable" &>/dev/null
    fi

    if [ "$win" = "$app_win" ] && [ "$REMAIN" = 1 ]; then
        read -r w_floating w_x w_y w_w w_h < <(
          jq -r '.container | "\(if .floating | IN("user_on", "auto_on") then 1 else 0 end) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"' <<<"$line"
        )
    fi

    if [ "$win" = "$app_win" ] && [ "$change" = close ]; then
      cleanup
    fi
  else
    buf+="$chunk"
  fi

  # Timeout logic
  if [ "$app_win" = none ] && [ "$TIMEOUT" -ne 0 ] && [ $(($(date +%s) - start_time)) -ge "$TIMEOUT" ]; then
    exit 0
  fi
done
