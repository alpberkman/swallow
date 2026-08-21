# swallow

An X11 command-line tool for making the terminal swallow GUI windows. So when you open a GUI app using swallow the GUI app will replace the terminal.

## Versions

- **`swallow-generic`**: Uses X11 API to hide the
  terminal and restores it later, targeting Openbox and other floating window managers. See
  [`swallow-generic/README.md`](swallow-generic/README.md).
- **`swallow-i3`**: The same idea for i3 and sway, written as a shell script on top of their IPC instead of raw X11. See
  [`swallow-i3/README.md`](swallow-i3/README.md).
- **`swallow-embed`**: Uses X11 API. Instead of hiding the
  terminal and opening a separate app window, it reparents the app's
  window directly into the terminal's own window, so no second window ever appears. See [`swallow-embed/README.md`](swallow-embed/README.md).
- **`swallow-wm`**: a standalone kiosk window manager (`mwm`), unrelated that forces the newest GUI app to be on top. Uses Xephyr. See [`swallow-wm/README.md`](swallow-wm/README.md).

## The two helper scripts

- **`swallow-auto.sh`**, used to pick the correct version depending on your setup/wm and filter the cli args.
- **`shell-integration.sh`**: wraps a list of GUI apps you choose in
  same-named bash functions, so typing `gui-app` runs swallow. `make install` wires it into `~/.bashrc`, but it does nothing until you fill in `SWALLOW_APPS`.

## Build

```sh
make
```

That's it. See the per-version READMEs linked above for install,
usage, and testing.
