# swallow-wm

This is `mwm`: a minimal kiosk window manager. It is not part of
`swallow`'s hide-and-restore job. It is a separate, standalone tool
that happens to live in this repo. `mwm` manages its own root window.
It does not integrate with `swallow-generic` or `swallow-i3`.

`mwm` has one job: keep exactly one window full-screen at a time, with
a fixed, simple rule for which window that is.

## Behavior

- The newest mapped window fills the screen.
- `Ctrl+Q` closes the window under the pointer.
- A screen size change resizes the top window to match. This matters
  most for a live Xephyr resize. A live resize sends an RandR
  `RRScreenChangeNotify` event, not a plain root `ConfigureNotify`.
- When the top window closes, the window under the pointer becomes the
  new top window.
- Popups, such as menus and tooltips, set `override_redirect`. `mwm`
  maps them as is. It never treats a popup as the new top window.

`mwm` needs its own root window with `SubstructureRedirectMask`. Only
one process can hold that on a given root at a time. If you already
run a window manager, such as i3, sway, or Openbox, `mwm` cannot also
manage your real desktop. Run it inside a nested X server instead. See
`swallow-wm.sh` below.

## Requirements

- Xlib and the Xrandr extension (`libx11-dev`, `libxrandr-dev`,
  depending on your distro)
- `pkg-config`
- A C11 compiler
- `Xephyr`, to run `mwm` in a nested session (`swallow-wm.sh`)
- `xclip`, for `swallow-wm.sh`'s clipboard bridge between the host and
  the nested session

## Build

```sh
make
```

This builds one `mwm` binary. It puts it in `../bin/`.

## Install

```sh
make install                    # installs to ~/.local/bin
make install PREFIX=/usr/local  # or any other prefix (needs sudo for a system dir)
make uninstall
```

This installs the `mwm` binary and the `swallow-wm` launcher script.
`swallow-wm` looks up `../bin/mwm` from its own location. This still
finds `mwm` once installed, since both files land in the same bindir.

The repo's top-level `make install` also runs this install. It does so
as part of installing everything in the repo. See the main
[`../README.md`](../README.md).

## Usage

```sh
swallow-wm <command> [args...]
```

This starts a throwaway, nested Xephyr session. It runs `mwm` inside
that session. It runs `<command>` inside that session too. For
example:

```sh
swallow-wm lxterminal
```

Closing Xephyr's window, or closing the app, ends the session. It also
cleans up the other processes.

## How it works

- `swallow-wm.sh` starts `Xephyr -displayfd 3`. This flag makes Xephyr
  pick a free display number by itself. Xephyr writes that number to
  fd 3, once it is ready to accept connections. This is a true
  readiness signal, not a sleep, and not a poll loop.
- The script reads that display number through a named pipe
  (`mkfifo`). It sets `DISPLAY` to it. It then starts `mwm` and the
  requested app inside that Xephyr session.
- Xephyr is a separate X server. It has its own clipboard, with no
  link to the host's. `swallow-wm.sh` runs a background loop that
  polls both displays' `CLIPBOARD` selection with `xclip`, and pushes
  a change on either side to the other. There is no cross-display
  clipboard-change event to hook, so this has to poll, once a second.
- It waits for the first of the three main processes to stop: Xephyr,
  `mwm`, or the app. It then kills the rest, including the clipboard
  loop, and exits.
- Some window managers can destroy Xephyr's own host window without
  killing the Xephyr process itself. i3's default `kill` binding does
  this, for example. When this happens, Xephyr keeps running headless.
  `swallow-wm.sh` does not notice, until the app closes some other
  way. This is a known gap. It is not yet fixed.

## License

GPLv3 or later. See [`../LICENSE`](../LICENSE).
