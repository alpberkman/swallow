# swallow

A command-line tool that makes a terminal swallow GUI windows: run a
GUI app from the terminal, and the app's window takes the terminal's
place instead of opening alongside it.

## Versions

- **`swallow-generic`**: hides the terminal via raw X11 and restores
  it when the app closes. Targets Openbox and other floating window
  managers. See [`swallow-generic/README.md`](swallow-generic/README.md).
- **`swallow-i3`**: the same idea for i3 and sway, built on their IPC
  instead of raw X11. A shell script. See
  [`swallow-i3/README.md`](swallow-i3/README.md).
- **`swallow-embed`**: reparents the app's window directly into the
  terminal's own window (`XReparentWindow`), so no second window is
  ever created. See [`swallow-embed/README.md`](swallow-embed/README.md).
- **`swallow-wm`**: a standalone kiosk window manager (`mwm`). It runs a nested Xephyr session and always shows
  the newest window full-screen. See [`swallow-wm/README.md`](swallow-wm/README.md).

## The two helper scripts

- **`swallow-auto.sh`**: picks the right version above for your window
  manager and forwards the CLI args to it.
- **`shell-integration.sh`**: wraps a list of GUI apps you choose in
  same-named bash functions, so typing `gui-app` runs swallow on it.
  `make install` wires this into `~/.bashrc`, but it does nothing until
  you fill in `SWALLOW_APPS`.

## Build

```sh
make
```

That's it. See the per-version READMEs linked above for install,
usage, and testing.
