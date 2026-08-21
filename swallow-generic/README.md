# swallow-generic

The C/X11 implementation of `swallow`. Hides the terminal while the
app is open, restores it when the app closes. Targets Openbox and
other floating window managers.

Also works under i3, but only the hide/restore part — the placement
flags (`--occupy`, `-x/-y/-w/-l`, etc.) rely on EWMH geometry requests
that i3 mostly ignores. Use `swallow-i3` there instead.

## Requirements

- Xlib (`libx11-dev` / `libX11-devel`)
- `pkg-config`
- A C11 compiler
- Optional, for tests: `Xephyr`, `openbox`, `xdotool`, `xprop`

## Build

```sh
make
```

Builds `../bin/swallow-generic`.

## Install

```sh
make install                    # ~/.local/bin
make install PREFIX=/usr/local  # or any other prefix (needs sudo for a system dir)
make uninstall
```

Prefer the repo's top-level `make install` (see
[`../README.md`](../README.md)) unless you only want this binary.

## Usage

```sh
swallow-generic [options] <command> [args...]
```

```sh
swallow-generic pcmanfm
swallow-generic --occupy --remain --timeout 0 zathura document.pdf
```

The terminal unmaps (fully, so it drops out of the taskbar) as soon as
the app's window appears, and remaps when that window closes.

### Options

| Flag | Long form | Description |
|---|---|---|
| `-x <n>` | `--x <n>` | X position for the new window |
| `-y <n>` | `--y <n>` | Y position for the new window |
| `-w <n>` | `--width <n>` | Width for the new window |
| `-l <n>` | `--length <n>` | Height for the new window |
| `-d` | `--default` | Let the window manager choose size/position (the default) |
| `-o` | `--occupy` | Put the new window in the terminal's exact spot |
| `-f` | `--full-screen` | Start the new window full-screen |
| `-t <n>` | `--timeout <n>` | Give up if no window appears within n seconds (default 3; 0 waits forever; capped at 3600) |
| `-r` | `--remain` | On close, put the terminal wherever the app's window ended up, not its original spot |
| `-k` | `--kill` | On close, close the terminal instead of restoring it |
| `-h` | `--help` | Show usage and exit |

Notes:

- `--default` and `--occupy` can't combine. `-x/-y/-w/-l` work alone or
  together for manual placement; skip an axis to leave it to the app
  or WM. They can't combine with `--occupy` either, since it already
  sets the full geometry.
- `--full-screen` adds to the other placement options, it doesn't
  replace them, and is also where the window returns to when
  full-screen turns off.
- `--timeout` guards against a command that never opens a window: a
  typo, a crash, a non-GUI command, a slow-starting Java IDE. Caps at
  3600 seconds; `0` is exempt and waits forever.
- `--kill` and `--remain` can't combine.

## How it works

- The terminal is whatever window is active (`_NET_ACTIVE_WINDOW`)
  when `swallow-generic` starts.
- The app's window is "the next new top-level window created and
  mapped," never matched by PID. Many apps hand off the window to an
  unrelated process: fork+exec launchers, double-fork daemonizing,
  D-Bus/single-instance activation.
- The terminal is hidden by an unmap (ICCCM Normal to Withdrawn),
  restored by a map, with geometry reasserted and focus returned.
- Waits for the target window with `poll()` on the X connection.
  `--timeout` bounds it.
- `--occupy`/manual placement is set before the window maps, and
  reasserted after as a fallback. Openbox and others otherwise map a
  window at its default spot first, then jump it, which flashes. Size
  is pinned as a temporary min/max, not just a hint, since toolkits
  resize new windows to fit their content and would win that race
  otherwise.
- With `--remain`, the app window's position and size are tracked
  continuously, using the app's own decoration insets (not the
  terminal's) to convert into the terminal's restored size. Using the
  terminal's insets would drift the terminal's size on repeated
  `--occupy --remain` cycles.
- Restoring the terminal sets geometry directly before mapping,
  instead of asking the WM for it. Openbox otherwise remaps to the old
  spot first and jumps after, another flash. A `WM_NORMAL_HINTS`
  position hint is set too, as a fallback.
- `--kill` sends `WM_DELETE_WINDOW` directly to the terminal (same
  message `wmctrl -c` sends). It's a request, not a forced kill; a
  terminal without protocol support gets `XKillClient` instead.

## Testing

```sh
make test
```

Run from the repo root. Real integration suite, throwaway nested
`Xephyr` + `openbox` session, never touches your real desktop. Skips
cleanly if `Xephyr`/`openbox`/`xdotool`/`xprop` are missing. Adds extra
scenarios against `zathura`, `kate`, `pcmanfm`, `xterm` if installed.
See [`../tests/`](../tests/).

## License

GPLv3 or later. See [`../LICENSE`](../LICENSE).
