# swallow

This is a minimal X11 command-line tool for Linux. It launches a GUI
application from a terminal and makes the terminal window swallow the
GUI. The options can partly control the placement of the GUI application
and the terminal, but the window manager makes the final decision. This
tool targets Openbox, but it uses only standard ICCCM/EWMH conventions.
It should work with any reasonably compliant reparenting window manager.

If you use i3 or sway, see [`swallow-i3/`](swallow-i3/README.md) for an
alternative implementation built on their IPC. See
[`swallow-auto.sh`](swallow-auto.sh) below. It picks between the two
implementations automatically, based on which window manager is running,
so you can use one setup with both.

## Components

The repo builds and installs four pieces. Day to day, you invoke only
`swallow` (directly, or through the shell integration below), and it
picks the rest:

- **`swallow-generic`** (this doc): the C/X11 binary, documented below.
  It works with any reasonably compliant reparenting window manager,
  Openbox included.
- **[`swallow-i3/`](swallow-i3/README.md)**: a separate bash
  implementation for i3/sway, built on their IPC instead of raw X11. It
  has its own build-free install, its own flags, and its own README. It
  shares no code with `swallow-generic` beyond the name and the general
  idea.
- **[`swallow-auto.sh`](swallow-auto.sh)**: installed as `swallow`, the
  command you type day to day. It detects whether i3/sway is actually
  running, not just installed, and dispatches to `swallow-i3` or
  `swallow-generic` accordingly. It strips `swallow-generic`-only flags
  first when it picks `swallow-i3`; the rest pass through unchanged,
  since `swallow-i3` understands them too (see
  [`swallow-i3/README.md`](swallow-i3/README.md#options)). This is what
  makes one setup work across window managers.
- **[`shell-integration.sh`](#shell-integration)**: wraps a fixed list
  of GUI apps in same-named bash functions that call `swallow-auto`. You
  type `kate file.txt` instead of `swallow-auto --occupy --remain
  --timeout 3 kate file.txt`. This piece is optional. `make install`
  wires it into `~/.bashrc` for you, but it stays inert until you fill
  in `SWALLOW_APPS`.

## Requirements

- Xlib (`libx11`, `libx11-dev` / `libX11-devel`, depending on your
  distro)
- `pkg-config`
- A C11 compiler
- Optional, for running the test suite: `Xephyr`, `openbox`, `xdotool`,
  `xprop`

## Build

```sh
make
```

This produces a single `swallow-generic` binary in `bin/`.

## Install

```sh
make install                    # installs to ~/.local/bin
make install PREFIX=/usr/local  # or any other prefix (needs sudo for a system dir)
```

This installs three commands: `swallow` (`swallow-auto.sh`, the
dispatcher you run directly; it picks between `swallow-generic` and
`swallow-i3` based on the running window manager), `swallow-generic`
itself (the compiled C/X11 binary), and `swallow-i3` (the i3/sway script
in `swallow-i3/`, copied in as-is; it has no build step of its own).

It also sets up [shell integration](#shell-integration) in
`~/.bashrc`: an empty `SWALLOW_APPS=()` line, a default
`SWALLOW_FLAGS=...` line, and a `source` line for
`shell-integration.sh`. Each line is added only if it is not already
present, so you can run `make install` again later without losing edits
you made to either line.

```sh
make uninstall
```

`uninstall` removes the three installed commands. It leaves your
`~/.bashrc` edits alone.

## Packaging (.deb)

```sh
sudo apt-get install debhelper pkg-config libx11-dev  # build deps
make deb
sudo apt install ../swallow_0.1.0-1_amd64.deb
```

This builds `swallow`, `swallow-generic`, and `swallow-i3` into
`/usr/bin`, and `shell-integration.sh` into `/usr/share/swallow/`.
Unlike `make install`, packaging does **not** touch `~/.bashrc`: there
is no single right user to do that for, from a postinst script. So
installing the `.deb` prints a note with the three lines to add
yourself, if you want [shell integration](#shell-integration).
`debian/rules` uses the Makefile's `install-files` target for this,
which installs only the commands, not `install`, which also does the
`~/.bashrc` wiring.

`dpkg-buildpackage` also skips `make test`. The test suite needs a real
X session (Xephyr, Openbox, xdotool) that a package build environment
does not have.

## Usage

```sh
swallow [options] <command> [args...]
```

Run whatever you would normally run from the terminal, with `swallow`
in front. For example:

```sh
swallow pcmanfm
swallow --occupy --remain --timeout 0 zathura document.pdf
```

The terminal window disappears (fully unmapped, not just minimized, so
it also drops out of the taskbar) as soon as the launched app's window
appears. It reappears as soon as that window closes.

### Options

These options control the size and placement of both the GUI
application and the terminal.

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

- With no options, `swallow` behaves like `--default`.
- `--default` and `--occupy` are mutually exclusive.
- Use `-x`/`-y`/`-w`/`-l` alone or together for manual placement. Any
  axis you do not give is left to the app or the window manager. You
  cannot combine them with `--occupy`, since `--occupy` already sets
  the full geometry itself; `swallow` rejects this combination outright
  instead of letting one silently override the other.
- `--full-screen` composes with the other options; it does not replace
  them. It is an EWMH state layered on top, and it is the geometry the
  window returns to when full-screen is turned off. For example,
  `swallow --occupy --full-screen kate` starts full-screen, then
  un-full-screens back into the terminal's old spot.
- `--timeout` guards against a command that never opens a window, such
  as a typo in the binary name, a crash on startup, or a non-GUI
  command. Without it, `swallow` would wait forever. Some applications
  take a long time to start their GUI, Java programs and IDEs
  especially, so a short timeout can stop `swallow` from ever hiding
  the terminal for those.
- A finite `--timeout` is capped at 3600 seconds (1 hour). Past that
  point it serves the same purpose as `--timeout 0` (wait forever). `0`
  itself is exempt, since it deliberately means unlimited.
- `--kill` and `--remain` are mutually exclusive. `--remain` only
  controls where the terminal is restored to, which does not matter if
  it is closed instead.

## Shell integration

`shell-integration.sh` wraps a fixed list of GUI apps in bash functions,
so you can type `kate somefile.txt` instead of `swallow --occupy
--remain --timeout 3 kate somefile.txt` every time. `make install` sets
this up in `~/.bashrc` for you:

```sh
SWALLOW_APPS=()
SWALLOW_FLAGS="--remain --occupy --timeout 3"
source /path/to/swallow/shell-integration.sh
```

Fill in `SWALLOW_APPS` with whatever you want wrapped, for example
`SWALLOW_APPS=(kate gimp mpv feh zathura)`, and adjust `SWALLOW_FLAGS`
to taste. Each app in the list gets a same-named bash function. This
function shadows the real binary for interactive shell use only;
`.desktop` launchers and scripts that call the binary directly are not
affected. Use `command kate` to bypass the wrapper. The functions call
the auto-dispatcher (`swallow-auto.sh`, installed as `swallow`), not
`swallow-generic` directly, so the same setup works whether you are
running Openbox, i3, or sway that session. See `swallow-auto.sh`.

## How it works

This section covers the `swallow-generic` binary specifically. See
[`swallow-i3/README.md`](swallow-i3/README.md#how-it-works) for how the
i3/sway implementation works instead. The two share no mechanism.

- The terminal is whatever window is active (`_NET_ACTIVE_WINDOW`) at
  the moment `swallow-generic` starts.
- The script identifies the launched app's window as the next new
  top-level window to be created and mapped. It does not match by PID,
  since many apps hand off to a process with no relationship to what
  was actually exec'd: fork+exec launchers, double-fork daemonizing, or
  D-Bus/single-instance activation handing the window to an
  already-running process entirely.
- The terminal is hidden by an unmap (ICCCM Normal to Withdrawn) and
  restored by a map, with its geometry explicitly reasserted and focus
  returned to it.
- `swallow-generic` waits for that window with `poll()` on the X
  connection, bounded by `--timeout`, rather than blocking forever. This
  way, a command that never opens a window does not hang
  `swallow-generic` indefinitely.
- `--occupy`, or manual placement, is set on the new window before it
  is ever mapped, and reasserted right after as a fallback. Some window
  managers, Openbox included, otherwise map a brand new window at its
  own default placement first, then jump it to the requested spot an
  instant later. This jump is just as visible as the terminal's own
  restore flash, described below. The requested size is also pinned as
  a temporary min/max constraint, not just an initial hint. Otherwise a
  real app's own self-resize, which most GUI toolkits do to fit their
  initial window to their content, can win the same race and cause the
  same kind of flash, for size instead of position.
- With `--remain`, `swallow-generic` tracks the app window's on-screen
  position and size as it moves or resizes, not just once. The terminal
  ends up wherever the app window was left right before it closed, no
  matter how many times it moved in between. `swallow-generic` tracks
  the app window's decoration insets the same way, and uses them,
  instead of the terminal's own insets, to convert the tracked
  rectangle into the terminal's requested size. Otherwise, repeated
  `--occupy --remain` cycles would slowly drift the terminal's size
  whenever the app's decorations do not exactly match the terminal's.
- Restoring the terminal sets its target geometry directly, before
  mapping it, rather than just asking the window manager for it. Some
  window managers, Openbox included, otherwise remap a previously
  hidden window straight back to its old spot, then jump it to the
  correct spot an instant later: a visible flash on every restore. A
  `WM_NORMAL_HINTS` position hint is set too, as a fallback for window
  managers that behave differently.
- With `--kill`, none of the restore step above happens. Instead,
  `swallow-generic` sends the terminal a `WM_DELETE_WINDOW` message
  directly, the same protocol message `wmctrl -c` or a window manager's
  own close button uses. This is a request, not a forced kill: an
  ICCCM-compliant terminal can still decline it, for example to prompt
  on unsaved output, exactly as if its own close button had been
  clicked. A terminal that does not support the protocol at all gets
  its connection forcibly closed instead.

## Testing

```sh
make test
```

This runs a real integration suite in a throwaway, nested `Xephyr` and
`openbox` session. It never touches your actual desktop. The suite
skips cleanly if `Xephyr`, `openbox`, `xdotool`, or `xprop` are not
installed, and it adds extra scenarios against `zathura`, `kate`,
`pcmanfm`, and `xterm` if those happen to be installed too.

`swallow-i3/` has its own, separate suite,
`swallow-i3/test-i3.sh`. It covers the i3/sway implementation the same
way, against a throwaway, nested i3 session. See
[`swallow-i3/README.md`](swallow-i3/README.md#testing). `make test` at
the repo root does not run it.

## License

GPLv3 or later. See [`LICENSE`](LICENSE).

## Note

AI was used in the development of this project.
