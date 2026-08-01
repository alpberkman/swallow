# swallow

A minimal X11 command-line tool for Linux: when launching a GUI application from a terminal, make the terminal window swallow the GUI. Placement of the the GUI application and the terminal can be partly be controlled by the options. However it is conclusively decided by the window manager. Targets Openbox, but relies only on standard ICCCM/EWMH conventions, so it
should work with any reasonably-compliant reparenting window manager.

If you use i3 or sway, see [`swallow-i3/`](swallow-i3/README.md) for an
alternative implementation built on their IPC instead -- and
[`swallow-auto.sh`](swallow-auto.sh) below, which picks between the two
automatically depending on which WM is actually running, so you can use
one setup across both.

## Requirements

- Xlib (`libx11`, `libx11-dev` / `libX11-devel` depending on distro)
- `pkg-config`
- A C11 compiler
- Optional, for running the test suite: `Xephyr`, `openbox`, `xdotool`, `xprop`

## Build

```sh
make
```

This produces a single `swallow` binary in `bin/`.

## Install

```sh
make install                    # installs to ~/.local/bin
make install PREFIX=/usr/local  # or any other prefix (needs sudo for a system dir)
```

Installs three commands: `swallow` itself, `swallow-auto` (picks between
`swallow` and `swallow-i3` based on the running WM -- see
`swallow-auto.sh`), and `swallow-i3` (the i3/sway-specific script in
`swallow-i3/`, copied in as-is -- it has no build step of its own).

It also sets up [shell integration](#shell-integration) in `~/.bashrc`:
an empty `SWALLOW_APPS=()` line, a default `SWALLOW_FLAGS=...` line, and a
`source` line for `shell-integration.sh`, all added only if not already
present -- safe to run `make install` again later without losing edits
you've made to either line.

```sh
make uninstall
```

`uninstall` removes the three installed commands but leaves your
`~/.bashrc` edits alone.

## Usage

```sh
swallow [options] <command> [args...]
```

Run whatever you'd normally run from the terminal, prefixed with `swallow`.
For example:

```sh
swallow pcmanfm
swallow --occupy --remain --timeout 0 zathura document.pdf
```

The terminal window disappears (not minimized -- fully unmapped, so it drops
out of the taskbar too) as soon as the launched app's window appears, and
reappears as soon as that window closes.

### Options

These options control the size and placement of both the GUI applicaiton and the terminal.

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
| `-k` | `--kill` | When the app's window closes, close the terminal instead of restoring it |
| `-h` | `--help` | Show usage and exit |

Notes:

- With no options at all, behavior is the same as `--default`.
- `--default` and `--occupy` are mutually exclusive.
- `-x`/`-y`/`-w`/`-l` can be used individually or together for manual
  placement; any axis not given is left to the app/WM. They can't be
  combined with `--occupy`, which already determines the full geometry
  itself -- rejected outright rather than one silently overriding the other.
- `--full-screen` composes with the other options rather than replacing
  them: it's an EWMH *state* layered on top, and it's the geometry the
  window returns to if full-screen is later turned off -- so e.g.
  `swallow --occupy --full-screen kate` starts full-screen but un-fullscreens
  back into the terminal's old spot.
- `--timeout` guards against a command that never opens a window (a typo'd
  binary, a crash on startup, a non-GUI command) -- without it, `swallow`
  would otherwise wait forever. However some applications might take a very long time to initialize their GUI (especially Java programs and IDEs) so having a very short timeout might prevent swallow to hide the terminal.
- `--kill` and `--remain` are mutually exclusive -- `--remain` only controls
  where the terminal is restored to, which is moot if it's closed instead.

## Shell integration

`shell-integration.sh` wraps a fixed list of GUI apps in bash functions so
you can just type `kate somefile.txt` instead of `swallow --occupy
--remain --timeout 3 kate somefile.txt` every time. `make install` sets
this up in `~/.bashrc` for you:

```sh
SWALLOW_APPS=()
SWALLOW_FLAGS="--remain --occupy --timeout 3"
source /path/to/swallow/shell-integration.sh
```

Fill in `SWALLOW_APPS` with whatever you want wrapped, e.g.
`SWALLOW_APPS=(kate gimp mpv feh zathura)`, and adjust `SWALLOW_FLAGS` to
taste. Each app in the list gets a same-named bash function that shadows
the real binary for interactive shell use only (`.desktop` launchers and
scripts calling the binary directly are unaffected; use `command kate` to
bypass the wrapper). The functions call `swallow-auto`, not `swallow`
directly, so the same setup works whether you're running Openbox, i3, or
sway that session -- see `swallow-auto.sh`.

## How it works

- The terminal is whatever window is active (`_NET_ACTIVE_WINDOW`) at the
  moment `swallow` starts.
- The launched app's window is identified as the next new top-level window
  to be created and mapped -- not matched by PID, since many apps hand off to
  a process with no relationship to what was actually exec'd (fork+exec
  launchers, double-fork daemonizing, or D-Bus/single-instance activation
  handing the window to an already-running process entirely).
- The terminal is hidden via unmap (ICCCM Normal -> Withdrawn) and restored
  via map, with its geometry explicitly reasserted and focus returned to it.
- Waiting for that window is done with `poll()` on the X connection, bounded
  by `--timeout`, rather than blocking forever -- so a command that never
  opens a window doesn't hang `swallow` indefinitely.
- `--occupy`/manual placement is set on the new window *before* it's ever
  mapped (as well as being reasserted right after, as a fallback), not just
  after -- some WMs (Openbox included) otherwise map a brand new window at
  its own default placement first, only jumping to the requested spot an
  instant later, which is just as visible a flash/jump as the terminal's own
  restore below. The requested size is also pinned as a temporary min/max
  constraint, not just an initial hint -- otherwise a real app's own
  self-resize (most GUI toolkits fit their initial window to their content)
  can win the same race and cause the same kind of flash, just for size
  instead of position.
- With `--remain`, the app window's on-screen position/size is tracked as it
  moves or resizes (not just captured once), so the terminal ends up
  wherever it was left right before closing, however many times it moved in
  between. Its decoration insets are tracked the same way and used (instead
  of the terminal's own) to convert that into the terminal's requested size --
  otherwise `--occupy --remain` cycles would slowly drift the terminal's size
  whenever the app's decorations don't exactly match the terminal's.
- Restoring the terminal sets its target geometry directly (before mapping
  it) rather than just asking the WM for it, since some WMs (Openbox
  included) otherwise remap a previously-hidden window straight back to
  where it was before, only jumping to the correct spot an instant later --
  a visible flash/jump on every restore. A `WM_NORMAL_HINTS` position hint
  is set too, as a fallback for WMs that behave differently.
- With `--kill`, none of the restore step above happens -- instead
  `swallow` sends the terminal a `WM_DELETE_WINDOW` message directly (the
  same protocol message `wmctrl -c` or a WM's own close button use). It's
  a request, not a forced kill: an ICCCM-compliant terminal can still
  decline (e.g. prompt on unsaved output) exactly as if its own close
  button had been clicked; a terminal that doesn't support it at all gets
  its connection forcibly closed instead.

## Testing

```sh
make test
```

Runs a real integration suite in a throwaway nested `Xephyr` + `openbox`
session -- it never touches your actual desktop. The suite skips cleanly if
`Xephyr`/`openbox`/`xdotool`/`xprop` aren't installed, and opportunistically
adds a couple of extra scenarios against `zathura`/`kate` if those happen to
be installed too.

## License

Add a license before publishing if you want one -- none is currently included.

## Note

AI was used in the development of this project.
