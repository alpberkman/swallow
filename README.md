# swallow

A minimal X11 command-line tool for Linux: launch a GUI application from a
terminal, hide the terminal while the app's window is open, and bring the
terminal back — in its original position and size — when the app closes.

Targets Openbox, but relies only on standard ICCCM/EWMH conventions, so it
should work with any reasonably-compliant reparenting window manager.

## Requirements

- Xlib (`libx11`, `libx11-dev` / `libX11-devel` depending on distro)
- `pkg-config`
- A C11 compiler
- Optional, for running the test suite: `Xephyr`, `openbox`, `xdotool`, `xprop`

## Build

```sh
make
```

This produces a single `swallow` binary in the project root.

## Install

```sh
make install                 # installs to /usr/local/bin
make install PREFIX=~/.local # or any other prefix
```

```sh
make uninstall
```

## Usage

```sh
swallow [options] <command> [args...]
```

Run whatever you'd normally run from the terminal, prefixed with `swallow`.
For example:

```sh
swallow firefox
swallow --occupy zathura document.pdf
```

The terminal window disappears (not minimized — fully unmapped, so it drops
out of the taskbar too) as soon as the launched app's window appears, and
reappears in its original spot as soon as that window closes.

### Options

All options control only where/how the *new* window is placed; they have no
effect on the terminal's restore behavior, which always returns it to
exactly where it was.

| Flag | Long form | Description |
|---|---|---|
| `-x <n>` | `--x <n>` | X position for the new window |
| `-y <n>` | `--y <n>` | Y position for the new window |
| `-w <n>` | `--width <n>` | Width for the new window |
| `-l <n>` | `--length <n>` | Height for the new window |
| `-d` | `--default` | Let the window manager choose size/position (the default) |
| `-o` | `--occupy` | Make the new window occupy the terminal's exact spot |
| `-f` | `--full-screen` | Start the new window full-screen |
| `-t <n>` | `--timeout <n>` | Give up if no window appears within n seconds (default 3; 0 waits forever) |
| `-r` | `--remain` | When the app's window closes, put the terminal where that window ended up instead of restoring its own original spot |
| `-h` | `--help` | Show usage and exit |

Notes:

- With no options at all, behavior is the same as `--default`.
- `--default` and `--occupy` are mutually exclusive.
- `-x`/`-y`/`-w`/`-l` can be used individually or together for manual
  placement; any axis not given is left to the app/WM.
- `--full-screen` composes with the other options rather than replacing
  them: it's an EWMH *state* layered on top, and it's the geometry the
  window returns to if full-screen is later turned off — so e.g.
  `swallow --occupy --full-screen kate` starts full-screen but un-fullscreens
  back into the terminal's old spot.
- `--timeout` guards against a command that never opens a window (a typo'd
  binary, a crash on startup, a non-GUI command) — without it, `swallow`
  would otherwise wait forever. If it times out, `swallow` exits non-zero
  and the terminal is left untouched (it's never hidden until a window is
  actually found).
- `--remain` is a "reverse occupy": rather than the terminal always
  snapping back to exactly where it started, it follows the app instead —
  useful if you moved/resized the app window while using it and would
  rather the terminal picked up from there than jump back to its old spot.

## How it works

- The terminal is whatever window is active (`_NET_ACTIVE_WINDOW`) at the
  moment `swallow` starts.
- The launched app's window is identified as the next new top-level window
  to be created and mapped — not matched by PID, since many apps hand off to
  a process with no relationship to what was actually exec'd (fork+exec
  launchers, double-fork daemonizing, or D-Bus/single-instance activation
  handing the window to an already-running process entirely).
- The terminal is hidden via unmap (ICCCM Normal → Withdrawn) and restored
  via map, with its geometry explicitly reasserted and focus returned to it.
- Waiting for that window is done with `poll()` on the X connection, bounded
  by `--timeout`, rather than blocking forever — so a command that never
  opens a window doesn't hang `swallow` indefinitely.
- With `--remain`, the app window's on-screen position/size is tracked as it
  moves or resizes (not just captured once), so the terminal ends up
  wherever it was left right before closing, however many times it moved in
  between.

## Testing

```sh
make test
```

Runs a real integration suite in a throwaway nested `Xephyr` + `openbox`
session — it never touches your actual desktop. The suite skips cleanly if
`Xephyr`/`openbox`/`xdotool`/`xprop` aren't installed, and opportunistically
adds a couple of extra scenarios against `zathura`/`kate` if those happen to
be installed too.

## License

Add a license before publishing if you want one — none is currently included.
