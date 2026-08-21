# swallow-i3.sh

`swallow` for i3 and sway: hide the terminal while a GUI
app's window is open, restore it when the window closes. Uses i3 IPC
(`i3-msg` or `swaymsg`, plus `jq`) instead of raw X11/EWMH, which lets
it put the terminal in the scratchpad instead of just unmapping it,
and place the launched app directly into the terminal's tiled slot
through i3's tree model.

Works mostly okay but windows might flash while opening/closing an application and there is no guarantee that they will be placed in the correct location. Nonetheless it works fine with a small number of terminals or when always using the last/rightmost terminal.

Plain bash, no build step.

## Requirements

- `bash`, `jq`
- `i3-msg` (i3) or `swaymsg` (sway)
- A running i3 or sway session

## Install

Use the repo's top-level `make install` (see
[`../README.md`](../README.md)). Or install just this script:

```sh
chmod +x swallow-i3.sh
cp swallow-i3.sh ~/.local/bin/swallow-i3
```

## Usage

```sh
swallow-i3.sh [options] <command> [args...]
```

```sh
swallow-i3.sh --occupy --remain zathura document.pdf
swallow-i3.sh --full-screen mpv video.mp4
swallow-i3.sh --kill pcmanfm
```

### Options

| Flag | Long form | Description |
|---|---|---|
| `-o` | `--occupy` | Put the new window in the terminal's old spot |
| `-r` | `--remain` | Restore the terminal to the app window's last spot, not its own original spot |
| `-f` | `--full-screen` | Full-screen the app's window as soon as it appears |
| `-k` | `--kill` | Close the terminal when the app's window closes, instead of restoring it |
| `-t <n>` | `--timeout <n>` | Give up if no window appears within n seconds (default 3; 0 waits forever) |
| `-h` | `--help` | Show usage and exit |

Notes:

- `--occupy` matches the terminal's floating position or tiled size.
  i3 doesn't do this on its own.
- `--full-screen` layers on top of `--occupy`. i3 remembers the
  non-full-screen rectangle, so un-full-screening returns there.
- `--kill` sends the terminal i3's own `kill` command instead of
  bringing it back from the scratchpad.
- `--timeout` bounds the wait after the launched command's process
  exits. If it forks and backgrounds itself, there's no limit from
  this; the script still watches for the window event directly.

## How it works

- The terminal is whichever window has focus at start. Reads
  `$WINDOWID` if the terminal sets it, otherwise looks up the focused
  window with `get_tree`.
- Detects sway via `$SWAYSOCK`, then uses `i3-msg` or `swaymsg`. Same
  IPC protocol either way.
- Records the terminal's floating state and rectangle, and subscribes
  to i3's `window` event stream, before forking the child, so it can't
  miss the new-window event.
- On a new non-terminal window: sends the terminal to the scratchpad.
  With `--occupy`, also places the new window at the terminal's old
  rectangle (floating) or size (tiled); i3's own reflow doesn't
  reliably give a newly tiled window the exact freed-up size.
- On close: brings the terminal back with `scratchpad show` (which
  also focuses it). `--remain` uses the app window's rectangle at
  close time; without it, the terminal's original rectangle is used.
- Gives up after `--timeout` seconds if no matching window appears
  (typo, CLI-only program, crash). `--timeout 0` waits forever.
- On Ctrl-C or `kill` (`INT`/`TERM`), runs the same cleanup: restore or
  close per `--kill`.
- `--kill` sends i3's `kill` command to the terminal's window ID.

## Testing

```sh
../tests/test-i3.sh --xephyr ./swallow-i3.sh
```

Real integration suite, disposable nested Xephyr + i3 session. Covers
a direct launch, a detached/single-instance-style launch, a command
that never opens a window, `--timeout 0`, the app taking over the
terminal's tiled size, and a resize surviving into `--remain`. Needs
`Xephyr`, `i3`, `i3-msg`, `jq`.

Drop `--xephyr` to run against whatever i3 session `$DISPLAY` already
points at (useful for sway, which has no Xephyr-nestable equivalent
here).

Works against any `swallow-*` binary or script, not just this one:
`../tests/test-i3.sh --xephyr ../bin/swallow-generic` runs it against
the C version. See the script's comments for which scenarios pass or
fail there.

## License

GPLv3 or later. See [`../LICENSE`](../LICENSE).
