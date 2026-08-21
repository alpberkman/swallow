# swallow-embed

Instead of hiding the terminal and opening a separate window for the
app, this reparents the app's window directly into the terminal's
window (`XReparentWindow`). No second window is ever created.

## Requirements

- Xlib (`libx11-dev` / `libX11-devel`)
- `pkg-config`
- A C11 compiler
- Optional, for tests: `Xephyr`, `openbox`, `xdotool`, `xprop`

## Build

```sh
make
```

Builds `../bin/swallow-embed`.

## Install

```sh
make install                    # ~/.local/bin
make install PREFIX=/usr/local  # or any other prefix (needs sudo for a system dir)
make uninstall
```

## Usage

```sh
swallow-embed [-h|--help] [-s|--shift] [-c|--ctrl] [-a|--alt] [-S|--super] [-q|--quit-key <key>] [-k|--kill] [-t|--timeout <n>] <command> [args...]
```

Run from the terminal you want the app embedded into. Quit modifiers
default to `--ctrl` alone; `--quit-key` takes an X11 keysym name and
defaults to `q`.

## How it works

- Finds the active window (`term_win`).
- Grabs the quit hotkey (`--ctrl` alone by default) on `term_win`, and
  selects `SubstructureNotify` on root. Exits with an error if
  `--quit-key` has no keycode on the current keyboard, instead of
  silently installing a no-op hotkey.
- Forks, execs `<command>`, and tracks "the next new top-level window
  created and mapped" (candidate `CreateNotify` windows, a
  self-addressed `MapNotify`), never by PID. Gives up after
  `--timeout` seconds (default 3; 0 waits forever; capped at 15).
- Marks each candidate `override_redirect` before it maps. Without
  this, the real WM still holds `SubstructureRedirectMask` on root and
  wins the race to reparent the window into its own frame first, so
  nothing gets embedded.
- Reparents the found window into `term_win`, resizes it to fill, maps
  it, focuses it once mapped.
- The quit hotkey sends the embedded app `WM_DELETE_WINDOW`, falling
  back to `XKillClient` if it doesn't advertise support. `--kill`
  additionally closes `term_win` the same way once the app's window is
  gone.
- `term_win` is watched for `ConfigureNotify` while running; a resize
  resizes the embedded app to match.

## Testing

```sh
../tests/test-embed.sh
```

Same throwaway Xephyr+openbox pattern as `test-generic.sh`.

## License

GPLv3 or later. See [`../LICENSE`](../LICENSE).
