# swallow-wm

`mwm`: a minimal kiosk window manager. It gets the same result (only the app's window is ever visible) a different way.  `mwm` instead runs a whole nested Xephyr session where it's
the window manager, and just shows the newest window
full-screen. Every window that opens is bound to that Xephyr display,
so this applies to anything you run in the session automatically.
There's no need to call swallow, or wrap any individual app, to get
it but you should call the initial terminal with it.

The downside is a nested Xephyr session takes a moment to start, so
there's a short delay before the terminal appears. The upside is every
window opened afterward is swallowed automatically, with no per-app
setup.

## Requirements

- Xlib + Xrandr (`libx11-dev`, `libxrandr-dev`)
- `pkg-config`
- A C11 compiler
- `Xephyr`, for the nested session (`swallow-wm.sh`)
- `xclip`, for `swallow-wm.sh`'s clipboard bridge

## Build

```sh
make
```

Builds `../bin/mwm`.

## Install

```sh
make install                    # ~/.local/bin
make install PREFIX=/usr/local  # or any other prefix (needs sudo for a system dir)
make uninstall
```

Installs the `mwm` binary and the `swallow-wm` launcher script.
`swallow-wm` looks up `../bin/mwm` relative to itself, which still
works once installed since both land in the same bindir.

The repo's top-level `make install` runs this too. See
[`../README.md`](../README.md).

## Usage

```sh
swallow-wm <command> [args...]
```

Starts a throwaway nested Xephyr session, runs `mwm` and `<command>`
inside it:

```sh
swallow-wm lxterminal
```

Closing Xephyr's window, or the app, ends the session and cleans up.

### Behavior

- The newest mapped window fills the screen.
- `Ctrl+Q` closes the window under the pointer.
- A screen size change resizes the top window to match (uses RandR
  `RRScreenChangeNotify`, not a plain root `ConfigureNotify`; matters
  for a live Xephyr resize).
- When the top window closes, the window under the pointer becomes the
  new top window.
- Popups (menus, tooltips) set `override_redirect`; `mwm` maps them
  as-is and never treats one as the top window.

## How it works

- `swallow-wm.sh` starts `Xephyr -displayfd 3`, which picks a free
  display number itself and writes it to fd 3 once ready. A real
  readiness signal, not a sleep or poll loop.
- The script reads that display number via a named pipe (`mkfifo`),
  sets `DISPLAY`, then starts `mwm` and the app.
- Xephyr's clipboard is separate from the host's. `swallow-wm.sh` polls
  both displays' `CLIPBOARD` selection with `xclip` once a second and
  pushes changes across; there's no cross-display clipboard event to
  hook.
- Waits for the first of Xephyr, `mwm`, or the app to stop, then kills
  the rest (including the clipboard loop) and exits.
- Known gap: some window managers (e.g. i3's default `kill` binding)
  can destroy Xephyr's host window without killing the Xephyr process,
  leaving it running headless. `swallow-wm.sh` won't notice until the
  app closes some other way. Not fixed yet.

## License

GPLv3 or later. See [`../LICENSE`](../LICENSE).
