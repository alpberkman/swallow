# swallow

This is a minimal X11 command-line tool for Linux. It launches a GUI
app from a terminal. It makes the terminal swallow the GUI app's
window. The options can partly control the placement of the app and
the terminal. The window manager makes the final decision. This tool
targets Openbox. It uses only standard ICCCM and EWMH conventions. It
should work with any reparenting window manager that follows these
conventions well.

If you use i3 or sway, see [`swallow-i3/`](swallow-i3/README.md). This
is an alternative implementation. It uses i3/sway IPC instead. See
[`swallow-auto.sh`](swallow-auto.sh) below. It picks between the two
implementations for you. It picks based on which window manager is
running. This lets you use one setup with both.

## Components

The repo builds and installs four pieces. Day to day, you run only
`swallow`. You run it directly, or through the shell integration
below. It picks the rest for you:

- **[`swallow-generic/`](swallow-generic/README.md)**: the C/X11
  binary. It works with any reparenting window manager that follows
  ICCCM/EWMH well. This includes Openbox.
- **[`swallow-i3/`](swallow-i3/README.md)**: a separate bash
  implementation for i3/sway. It uses their IPC instead of raw X11. It
  has its own build-free install. It has its own flags. It has its own
  README. It shares no code with `swallow-generic`, beyond the name
  and the general idea.
- **[`swallow-auto.sh`](swallow-auto.sh)**: installed as `swallow`.
  This is the command you type day to day. It checks whether i3 or
  sway is actually running, not just installed. It then sends the call
  to `swallow-i3` or to `swallow-generic`. When it picks `swallow-i3`,
  it first strips flags that only `swallow-generic` understands. The
  rest of the flags pass through unchanged, since `swallow-i3`
  understands them too (see
  [`swallow-i3/README.md`](swallow-i3/README.md#options)). This is how
  one setup works across window managers.
- **[`shell-integration.sh`](#shell-integration)**: wraps a fixed list
  of GUI apps in same-named bash functions. Each function calls
  `swallow-auto`. You type `kate file.txt` instead of `swallow-auto
  --occupy --remain --timeout 3 kate file.txt`. This piece is
  optional. `make install` adds it to `~/.bashrc` for you. It stays
  inert until you fill in `SWALLOW_APPS`.

The repo also has [`swallow-wm/`](swallow-wm/README.md). This is a
separate, standalone kiosk window manager (`mwm`). It has no link to
`swallow`'s own hide-and-restore job. The top-level `make install`
installs it too. See its own README for its own usage.

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

This builds one `swallow-generic` binary. It puts it in `bin/`.

## Install

```sh
make install                    # installs to ~/.local/bin
make install PREFIX=/usr/local  # or any other prefix (needs sudo for a system dir)
```

This installs three commands:

- `swallow`: this is `swallow-auto.sh`. Run this one directly. It
  picks between `swallow-generic` and `swallow-i3`, based on the
  window manager you run.
- `swallow-generic`: the compiled C/X11 binary.
- `swallow-i3`: the i3/sway script from `swallow-i3/`. It is copied in
  as is. It has no build step of its own.

`make install` also sets up [shell integration](#shell-integration) in
`~/.bashrc`. It adds three lines: an empty `SWALLOW_APPS=()` line, a
default `SWALLOW_FLAGS=...` line, and a `source` line for
`shell-integration.sh`. It adds each line only if that line is not
there yet. You can run `make install` again later. It will not undo
edits you made to either line.

```sh
make uninstall
```

`uninstall` removes the three installed commands. It leaves your
`~/.bashrc` alone.

## Packaging (.deb)

```sh
sudo apt-get install debhelper pkg-config libx11-dev  # build deps
make deb
sudo apt install ../swallow_0.1.0-1_amd64.deb
```

This builds `swallow`, `swallow-generic`, and `swallow-i3` into
`/usr/bin`. It builds `shell-integration.sh` into
`/usr/share/swallow/`. Unlike `make install`, packaging does **not**
touch `~/.bashrc`. A postinst script has no single correct user to do
that for. So the `.deb` install prints a note instead. The note gives
you the three lines to add yourself, for [shell
integration](#shell-integration). `debian/rules` uses the Makefile's
`install-files` target for this. That target installs only the
commands. It skips the `~/.bashrc` step that `install` does.

`dpkg-buildpackage` also skips `make test`. The test suite needs a
real X session: Xephyr, Openbox, xdotool. A package build environment
does not have one.

## Usage

```sh
swallow [options] <command> [args...]
```

Run whatever you would normally run from the terminal. Put `swallow`
in front of it. For example:

```sh
swallow pcmanfm
swallow --occupy --remain --timeout 0 zathura document.pdf
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

- With no options, `swallow` acts like `--default`.
- `--default` and `--occupy` cannot combine.
- Use `-x`/`-y`/`-w`/`-l` alone or together for manual placement. Any
  axis you skip is left to the app or the window manager. You cannot
  combine these with `--occupy`. `--occupy` already sets the full
  geometry by itself. `swallow` rejects this combination outright,
  rather than letting one silently override the other.
- `--full-screen` adds to the other options; it does not replace them.
  It is an EWMH state, layered on top. It is also the geometry the
  window returns to when full-screen turns off. For example, `swallow
  --occupy --full-screen kate` starts full-screen. It then
  un-full-screens back into the terminal's old spot.
- `--timeout` guards against a command that never opens a window. This
  covers a typo in the binary name, a crash on startup, or a non-GUI
  command. Without it, `swallow` would wait forever. Some apps take a
  long time to start their GUI. Java apps and IDEs are the worst
  offenders. A short timeout stops `swallow` from hiding the terminal
  forever for those.
- A finite `--timeout` has a cap of 3600 seconds (1 hour). Past that
  point, it acts the same as `--timeout 0` (wait forever). `0` itself
  is exempt from the cap, since it deliberately means unlimited.
- `--kill` and `--remain` cannot combine. `--remain` only controls
  where the terminal is restored to. That does not matter if the
  terminal closes instead.

## Shell integration

`shell-integration.sh` wraps a fixed list of GUI apps in bash
functions. This lets you type `kate somefile.txt` instead of `swallow
--occupy --remain --timeout 3 kate somefile.txt` every time. `make
install` sets this up in `~/.bashrc` for you:

```sh
SWALLOW_APPS=()
SWALLOW_FLAGS="--remain --occupy --timeout 3"
source /path/to/swallow/shell-integration.sh
```

Fill in `SWALLOW_APPS` with the apps you want wrapped, for example
`SWALLOW_APPS=(kate gimp mpv feh zathura)`. Adjust `SWALLOW_FLAGS` to
your own taste. Each app in the list gets a same-named bash function.
This function shadows the real binary only in an interactive shell.
`.desktop` launchers and scripts that call the binary directly are not
affected. Use `command kate` to skip the wrapper. The functions call
the auto-dispatcher (`swallow-auto.sh`, installed as `swallow`), not
`swallow-generic` directly. So the same setup works whether you run
Openbox, i3, or sway that session. See `swallow-auto.sh`.

## How it works

Each implementation has its own README with its own mechanism notes:

- [`swallow-generic/README.md`](swallow-generic/README.md#how-it-works)
  covers the C/X11 binary.
- [`swallow-i3/README.md`](swallow-i3/README.md#how-it-works) covers
  the i3/sway script.

The two share no mechanism.

## Testing

```sh
make test
```

This runs two real integration suites, one after the other, each in a
throwaway, nested X session. Neither touches your real desktop.

`tests/test-generic.sh` covers the C/X11 binary, in a nested `Xephyr`
and `openbox` session. It skips cleanly if `Xephyr`, `openbox`,
`xdotool`, or `xprop` are missing. It adds extra scenarios against
`zathura`, `kate`, `pcmanfm`, and `xterm`, if those happen to be
installed too.

`tests/test-i3.sh` covers `swallow-i3/`, in a nested i3 session. See
[`swallow-i3/README.md`](swallow-i3/README.md#testing) for details.

## License

GPLv3 or later. See [`LICENSE`](LICENSE).

## Note

AI was used in the development of this project.
