# swallow-i3.sh

An i3/sway-specific alternative to `swallow`: same idea (hide the launching
terminal while a GUI app's window is open, restore it on close), but built
entirely on i3 IPC (`i3-msg`/`swaymsg` + `jq`) instead of raw X11/EWMH. It
trades `swallow`'s window-manager independence for i3/sway-specific
behavior that a generic X11 tool can't do on its own: putting the terminal
in the scratchpad instead of just unmapping it, and having the launched
app immediately take over the terminal's exact tiled slot (not just its
on-screen rect) via i3's own tree/container model.

Because it's plain bash, it needs no build step -- there's no C compiler or
libX11 involved for this version.

If you move between i3/sway and other window managers, `../swallow-auto.sh`
picks between this script and `swallow` automatically based on what's
actually running, so you don't need separate setups per WM -- see the main
`../README.md`'s "Shell integration" section.

## Requirements

- `bash`
- `jq`
- `i3-msg` (i3) or `swaymsg` (sway) -- whichever matches your running
  compositor is picked automatically, see below
- A running i3 or sway session

## Install

There's nothing to build. The simplest route is the repo's top-level
`make install` (see the main `../README.md`), which installs this as
`swallow-i3` alongside `swallow` and `swallow-auto` and wires up shell
integration for you. To install just this script standalone instead, make
it executable and put it on your `PATH` however you like, e.g.:

```sh
chmod +x swallow-i3.sh
cp swallow-i3.sh ~/.local/bin/swallow-i3
```

## Usage

```sh
swallow-i3.sh <command> [args...]
```

Run whatever you'd normally run from your terminal, prefixed with
`swallow-i3.sh`. For example:

```sh
swallow-i3.sh zathura document.pdf
```

Unlike `swallow`, there are no placement/timeout flags -- everything is
driven by i3/sway's own tiling and scratchpad behavior instead. The one
tunable is `GRACE` (default 10s), a constant at the top of the script: how
long to keep waiting for a window after the launched command's own process
has already exited, before giving up (see "How it works" below).

## How it works

- The terminal is whichever window is focused when `swallow-i3.sh` starts
  -- read from `$WINDOWID` if the terminal emulator sets it (most do),
  otherwise looked up via `get_tree`.
- Whether i3 or sway is running is detected from `$SWAYSOCK` (set by sway,
  never by i3); the script then goes through `i3-msg` or `swaymsg`
  uniformly, since both speak the same IPC protocol and command language.
- Before launching the command, the terminal's floating state and rect are
  captured, and the script subscribes to i3's `window` event stream --
  *before* forking the child, so the child's own "new window" event can't
  be missed in the gap.
- Once a new window (that isn't the terminal itself) is reported, the
  terminal is sent to the scratchpad (`move scratchpad`), and the new
  window is forced into the terminal's old spot: floating at the same
  rect if the terminal was floating, or resized to the same width/height
  if it was tiled (i3's own reflow doesn't reliably land a newly-tiled
  window at the exact freed-up size on its own).
- When that window closes, the terminal is brought back (`scratchpad
  show`, which also refocuses it) and either moved back to the app's
  last-known rect (if it was floating) or un-floated and resized to match
  (if it was tiled) -- using the closing app's *own* rect as of the close
  event, not the terminal's original one, so a resize done while the app
  was open sticks instead of being discarded.
- If no qualifying window ever shows up (typo'd command, a CLI-only
  program, a crash on startup), the script gives up `GRACE` seconds after
  the launched process itself exits, rather than hanging forever. If the
  process never exits either (e.g. it backgrounds/daemonizes), there's no
  overall cap -- the loop just keeps waiting for a window.
- `INT`/`TERM` (e.g. Ctrl-C) restore the terminal at its original
  pre-launch spot before exiting, since there's no app-close event to read
  a live rect from in that path.

## Differences from `swallow`

- i3/sway only, not portable to other window managers.
- No `-o/--occupy`, `-x/-y/-w/-l`, or `-f/--full-screen` flags -- placement
  is entirely i3/sway's tiling model plus the scratchpad swap described
  above, not manually specified geometry.
- No `-t/--timeout` flag; `GRACE` plays a related but narrower role (see
  above) and is a constant in the script, not a CLI option.
- Always behaves like `swallow --remain`: the terminal comes back at the
  app's last position/size, not its own original spot. There's no flag to
  opt out of this.
- Uses the scratchpad rather than a raw unmap, and actively resizes the
  launched app into the terminal's tiled slot -- the counterpart to
  `swallow`'s pre-map placement/flash-avoidance work, but achieved through
  i3/sway's own container model instead of X11 geometry hints.

## Testing

```sh
./test-i3.sh --xephyr ./swallow-i3.sh
```

Runs a real integration suite in a disposable nested Xephyr + i3 session,
covering: a direct app launch, a detached/single-instance-style launch, a
command that never opens a window, the app immediately taking over the
terminal's tiled size, and a resize while the app is open surviving into
the restored terminal. Requires `Xephyr`, `i3`, `i3-msg`, `jq`.

Drop `--xephyr` to instead run against whichever i3 session `$DISPLAY`
already points at (a real, already-running one) -- useful for testing
under sway, since sway has no Xephyr-nestable equivalent in this suite.

`test-i3.sh` is written generically against any `swallow-*` binary or
script, not just `swallow-i3.sh` -- e.g. `./test-i3.sh --xephyr
../bin/swallow` runs it against the C version instead. See the script's
own comments for which scenarios are expected to pass or fail for plain
`swallow` when run that way.

## Note

AI was used in the development of this project.
