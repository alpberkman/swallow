# swallow-i3.sh

This is an alternative to `swallow` for i3 and sway. It has the same
job: hide the terminal while a GUI app's window is open, and restore
the terminal when that window closes. It uses i3 IPC (`i3-msg` or
`swaymsg`, plus `jq`) instead of raw X11/EWMH. This gives it two
things a plain X11 tool cannot do on its own: it puts the terminal in
the scratchpad, instead of just unmapping it, and it can put the
launched app directly into the terminal's tiled slot, through i3's own
tree model.

This script is plain bash. It needs no build step and no C compiler.

If you switch between i3/sway and other window managers, use
`../swallow-auto.sh` instead. It picks between this script and
`swallow`, based on what is running. See the "Shell integration"
section in the main `../README.md`.

## Requirements

- `bash`
- `jq`
- `i3-msg` (i3) or `swaymsg` (sway). The script picks the right one by
  itself. See "How it works" below.
- A running i3 or sway session

## Install

There is nothing to build. The simplest way is the repo's top-level
`make install` (see the main `../README.md`). It installs this script
as `swallow-i3`, along with `swallow` and `swallow-auto`. It also sets
up shell integration for you.

To install just this script, make it executable and put it on your
`PATH`:

```sh
chmod +x swallow-i3.sh
cp swallow-i3.sh ~/.local/bin/swallow-i3
```

## Usage

```sh
swallow-i3.sh [options] <command> [args...]
```

Run whatever you would normally run from your terminal. Put
`swallow-i3.sh` in front of it. For example:

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

- `--occupy` sets the new window to a floating position, or a tiled
  size, to match the terminal. i3 does not do this step by itself.
- `--full-screen` full-screens the app's window on top of whatever
  `--occupy` set. i3 remembers the non-full-screen rectangle. So
  un-full-screening later returns to that spot.
- `--kill` sends the terminal i3's own `kill` command, instead of
  bringing it back from the scratchpad.
- With no `--remain`, the terminal returns to its own original spot.
  With `--remain`, it goes to the app window's last known spot
  instead.
- `--timeout` bounds how long the script waits for a window, after the
  launched command's own process exits. If that process never exits,
  for example if it forks and backgrounds itself, this option puts no
  limit on the wait. The script still watches for the window event.

## How it works

- The terminal is whichever window has focus when `swallow-i3.sh`
  starts. The script reads `$WINDOWID`, if the terminal emulator sets
  it. Most terminal emulators set it. Otherwise the script looks up
  the focused window with `get_tree`.
- The script checks `$SWAYSOCK` to detect sway. i3 never sets this
  variable. The script then uses `i3-msg` or `swaymsg`. Both use the
  same IPC protocol and commands.
- Before it launches the command, the script records the terminal's
  floating state and rectangle. It also subscribes to i3's `window`
  event stream. It does this before it forks the child process. So it
  cannot miss the child's own "new window" event.
- When a new window appears that is not the terminal, the script sends
  the terminal to the scratchpad (`move scratchpad`). With `--occupy`,
  it also puts the new window in the terminal's old spot: floating at
  the same rectangle, if the terminal was floating, or resized to the
  same width and height, if it was tiled. i3's own reflow does not
  reliably give a newly tiled window the exact freed-up size by
  itself.
- When that window closes, the script brings the terminal back
  (`scratchpad show`, which also gives it focus). With `--remain`, it
  uses the app window's own rectangle at the time of the close event,
  not the terminal's original one. So a resize made while the app was
  open stays in effect. Without `--remain`, it uses the terminal's own
  original rectangle instead.
- If no matching window ever appears, for example from a typo in the
  command, a command-line-only program, or a crash on startup, the
  script gives up `--timeout` seconds after launch. `--timeout 0`
  makes it wait forever instead.
- On Ctrl-C, or a normal `kill` (`INT`/`TERM`), the script runs the
  same cleanup: it restores the terminal, or closes it with `--kill`.
- `--kill` sends i3's own `kill` command to the terminal's window ID.
  This is the IPC equivalent of `swallow`'s `WM_DELETE_WINDOW`-then-
  `XKillClient` `close_window()` function.

## Differences from `swallow`

- This script only works with i3 and sway. `swallow` works with any
  reasonably compliant X11 window manager.
- There are no `-x/-y/-w/-l` manual-geometry flags. Placement always
  comes from i3/sway's own tiling model, plus the scratchpad move and
  `--occupy` described above.
- `--occupy`, `--remain`, `--full-screen`, `--kill`, and `--timeout`
  all exist here too, with the same names and the same meaning as in
  `swallow`.
- This script uses the scratchpad, not a raw X11 unmap. It also
  actively resizes the launched app into the terminal's tiled slot.
  `swallow` does the equivalent job with pre-map X11 geometry hints
  instead.

## Testing

```sh
../tests/test-i3.sh --xephyr ./swallow-i3.sh
```

This runs a real integration suite in a disposable, nested Xephyr and
i3 session. It covers: a direct app launch, a detached/single-instance-
style launch, a command that never opens a window, `--timeout 0`
waiting forever, the app taking over the terminal's tiled size right
away, and a resize surviving into the restored terminal with
`--remain`. It needs `Xephyr`, `i3`, `i3-msg`, and `jq`.

Drop `--xephyr` to run against whichever i3 session `$DISPLAY` already
points at: a real, already-running one. This is useful for testing
under sway, since sway has no Xephyr-nestable equivalent in this
suite.

`test-i3.sh` works against any `swallow-*` binary or script, not just
`swallow-i3.sh`. For example, `../tests/test-i3.sh --xephyr
../bin/swallow-generic` runs it against the C version instead. See the
script's own comments for which scenarios pass or fail for
`swallow-generic`, when run that way.

## Note

AI was used in the development of this project.
