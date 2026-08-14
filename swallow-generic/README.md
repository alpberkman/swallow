# swallow-generic

This is the C/X11 implementation of `swallow`. It launches a GUI app
from a terminal. It makes the terminal swallow the app's window:
hidden while the app is open, restored when the app closes. It targets
Openbox. It uses only standard ICCCM and EWMH conventions. It should
work with any reparenting window manager that follows these
conventions well.

If you use i3 or sway, see
[`../swallow-i3/`](../swallow-i3/README.md). This is an alternative
implementation. It uses their IPC instead. See
[`../swallow-auto.sh`](../swallow-auto.sh). It picks between the two
for you, based on which window manager is running. This lets you use
one setup with both. See the main [`../README.md`](../README.md) for
how all the pieces in this repo fit together.

## Requirements

- Xlib (`libx11`, `libx11-dev` / `libX11-devel`, depending on your
  distro)
- `pkg-config`
- A C11 compiler
- Optional, for the test suite: `Xephyr`, `openbox`, `xdotool`,
  `xprop`

## Build

```sh
make
```

This builds one `swallow-generic` binary. It puts it in `../bin/`.

## Install

The simplest way is the repo's top-level `make install`. See the main
[`../README.md`](../README.md). It installs this binary as
`swallow-generic`, along with `swallow` and `swallow-i3`. It also sets
up shell integration for you.

To install just this binary:

```sh
make install                    # installs to ~/.local/bin
make install PREFIX=/usr/local  # or any other prefix (needs sudo for a system dir)
make uninstall
```

## Usage

```sh
swallow-generic [options] <command> [args...]
```

Run whatever you would normally run from the terminal. Put
`swallow-generic` in front of it. For example:

```sh
swallow-generic pcmanfm
swallow-generic --occupy --remain --timeout 0 zathura document.pdf
```

The terminal window disappears as soon as the app's window appears.
This is a full unmap, not a minimize, so it also drops out of the
taskbar. The terminal reappears as soon as the app's window closes.

### Options

These options control the size and placement of both the app and the
terminal.

| Flag | Long form | Description |
|---|---|---|
| `-x <n>` | `--x <n>` | X position for the new window |
| `-y <n>` | `--y <n>` | Y position for the new window |
| `-w <n>` | `--width <n>` | Width for the new window |
| `-l <n>` | `--length <n>` | Height for the new window |
| `-d` | `--default` | Let the window manager choose size/position (the default) |
| `-o` | `--occupy` | Make the new window occupy the terminal's exact spot |
| `-f` | `--full-screen` | Start the new window full-screen |
| `-t <n>` | `--timeout <n>` | Give up if no window appears within n seconds (default 3; 0 waits forever; capped at 3600) |
| `-r` | `--remain` | When the app's window closes, put the terminal where that window ended up instead of restoring its own original spot |
| `-k` | `--kill` | When the app's window closes, close the terminal instead of restoring it |
| `-h` | `--help` | Show usage and exit |

Notes:

- With no options, `swallow-generic` acts like `--default`.
- `--default` and `--occupy` cannot combine.
- Use `-x`/`-y`/`-w`/`-l` alone or together for manual placement. Any
  axis you skip is left to the app or the window manager. You cannot
  combine these with `--occupy`. `--occupy` already sets the full
  geometry by itself. `swallow-generic` rejects this combination
  outright, rather than letting one silently override the other.
- `--full-screen` adds to the other options; it does not replace them.
  It is an EWMH state, layered on top. It is also the geometry the
  window returns to when full-screen turns off. For example,
  `swallow-generic --occupy --full-screen kate` starts full-screen. It
  then un-full-screens back into the terminal's old spot.
- `--timeout` guards against a command that never opens a window. This
  covers a typo in the binary name, a crash on startup, or a non-GUI
  command. Without it, `swallow-generic` would wait forever. Some apps
  take a long time to start their GUI. Java apps and IDEs are the
  worst offenders. A short timeout stops `swallow-generic` from hiding
  the terminal forever for those.
- A finite `--timeout` has a cap of 3600 seconds (1 hour). Past that
  point, it acts the same as `--timeout 0` (wait forever). `0` itself
  is exempt from the cap, since it deliberately means unlimited.
- `--kill` and `--remain` cannot combine. `--remain` only controls
  where the terminal is restored to. That does not matter if the
  terminal closes instead.

## How it works

- The terminal is whatever window is active (`_NET_ACTIVE_WINDOW`) at
  the moment `swallow-generic` starts.
- `swallow-generic` treats the launched app's window as the next new
  top-level window to be created and mapped. It does not match by
  PID. Many apps hand the window off to a process with no link to
  what was actually exec'd. This covers fork+exec launchers,
  double-fork daemonizing, and D-Bus/single-instance activation that
  hands the window to an already-running process.
- The terminal is hidden by an unmap (ICCCM Normal to Withdrawn). It
  is restored by a map. Its geometry is reasserted, and focus returns
  to it.
- `swallow-generic` waits for that window with `poll()` on the X
  connection. `--timeout` bounds the wait, so a command that never
  opens a window does not hang `swallow-generic` forever.
- `--occupy`, or manual placement, is set on the new window before it
  is ever mapped. It is reasserted right after, as a fallback. Some
  window managers, Openbox included, otherwise map a brand new window
  at its own default spot first, then jump it to the requested spot
  an instant later. This jump is just as visible as the terminal's
  own restore flash, described below. The requested size is also
  pinned as a temporary min/max constraint, not just an initial hint.
  Otherwise a real app's own self-resize can win the same race. Most
  GUI toolkits resize their own window to fit their initial content.
  This causes the same kind of flash, for size instead of position.
- With `--remain`, `swallow-generic` tracks the app window's position
  and size as it moves or resizes, not just once. The terminal ends up
  wherever the app window sat right before it closed, no matter how
  many times it moved before that. `swallow-generic` also tracks the
  app window's decoration insets the same way. It uses those insets,
  not the terminal's own, to convert the tracked rectangle into the
  terminal's requested size. Otherwise, repeated `--occupy --remain`
  cycles would slowly drift the terminal's size, whenever the app's
  decorations do not exactly match the terminal's.
- Restoring the terminal sets its target geometry directly, before
  mapping it. It does not just ask the window manager for that
  geometry. Some window managers, Openbox included, otherwise remap a
  hidden window straight back to its old spot, then jump it to the
  correct spot an instant later. This is a visible flash on every
  restore. A `WM_NORMAL_HINTS` position hint is set too, as a fallback
  for window managers that behave differently.
- With `--kill`, none of the restore step above happens. Instead,
  `swallow-generic` sends the terminal a `WM_DELETE_WINDOW` message
  directly. This is the same protocol message that `wmctrl -c` or a
  window manager's own close button sends. This is a request, not a
  forced kill. An ICCCM-compliant terminal can still decline it, for
  example to prompt about unsaved output, exactly as if its own close
  button had been clicked. A terminal with no support for the
  protocol gets its connection forcibly closed instead.

## Testing

```sh
make test
```

Run this from the repo root. It runs a real integration suite. The
suite runs in a throwaway, nested `Xephyr` and `openbox` session. It
never touches your real desktop. It skips cleanly if `Xephyr`,
`openbox`, `xdotool`, or `xprop` are missing. It adds extra scenarios
against `zathura`, `kate`, `pcmanfm`, and `xterm`, if those happen to
be installed too. See [`../tests/`](../tests/).

## License

GPLv3 or later. See [`../LICENSE`](../LICENSE).
