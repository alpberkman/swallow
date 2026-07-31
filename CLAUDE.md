# swallow

A minimal C/X11 CLI tool for Linux (target WM: Openbox). It launches a GUI
app from a terminal, hides the terminal while the app's window is open, and
restores the terminal (position + size) when the app's window closes.

## Build / install / test

```
make            # builds ./swallow (needs pkg-config + libx11-dev)
make test       # builds test helpers, then runs the full integration suite
make install    # installs to $PREFIX/bin (default /usr/local/bin)
make clean
```

There is only one source file: `src/swallow.c`. No other build system, no
dependencies beyond libX11.

## How it works (see the header comment in src/swallow.c for full detail)

- The terminal is whatever window is active (`_NET_ACTIVE_WINDOW`) when
  swallow starts.
- The launched command's window is identified as "the next new top-level
  window to be created and mapped" — deliberately *not* matched by PID/process
  tree, since apps like Kate hand off to an unrelated pre-existing process via
  D-Bus/kdeinit single-instance activation with no process relationship to
  what was exec'd at all.
- `wait_for_target_window()` tracks candidate windows without an explicit
  list: X only delivers a *self-addressed* `MapNotify` (`event == window`) to
  a client that called `XSelectInput` directly on that window, so receiving
  one already proves it's a window swallow itself selected on. This also
  means every qualifying window is tracked concurrently, not just the first
  — needed because some apps (Kate) create a non-override-redirect helper
  window before their real one.
- The terminal is hidden via unmap (ICCCM Normal → Withdrawn, drops it from
  the taskbar/pager entirely) and restored via map + explicit geometry
  reassertion (`_NET_MOVERESIZE_WINDOW`) + `_NET_ACTIVE_WINDOW` focus.
- Placement of the new window is controlled by CLI flags: `-x/-y/-w/-l`
  (manual position/size, usable individually or together), `-d/--default`
  (leave it to the WM — also the behavior with no flags), `-o/--occupy` (take
  the terminal's exact spot, using `_NET_FRAME_EXTENTS` to convert
  frame↔client size), `-f/--full-screen` (composes with the others — it's an
  EWMH *state* layered on top of whatever normal geometry was set, not a
  replacement for it). Run `swallow --help` for the full list.
- `-t/--timeout <n>` (default 3s, 0 waits forever) bounds
  `wait_for_target_window()`: `poll()` on the X connection fd
  (`ConnectionNumber(dpy)`), not `select()` or a sleep-poll loop — both
  alternatives were tried and are worth knowing not to reintroduce. A
  sleep-poll loop (draining `XPending()` then `usleep()`-ing between checks)
  reliably failed to ever detect the target window's events in testing and
  even crashed a nested Xephyr server under repeated use; blocking directly
  on the connection fd is required, not just "nicer."

## Testing

`tests/run_tests.sh` is a real integration suite, not unit tests — it spins
up a throwaway Xephyr + Openbox session and drives it with `xdotool`/`xprop`.
Requires `Xephyr`, `openbox`, `xdotool`, `xprop`; the script skips (exit 0)
cleanly if they're missing. It also opportunistically tests against real
apps (`zathura`, `kate`) if installed, skipping those specific scenarios
otherwise.

Test helper binaries live in `tests/` and simulate specific real-world
launch patterns:
- `fork_exec_helper.c` — fork+exec launcher / double-fork daemonize style.
- `phantom_window_helper.c` — creates a never-mapped decoy window before
  exec'ing the real command, reproducing the Kate-style "non-override-redirect
  helper window appears first" case. This is the regression test for why
  `wait_for_target_window` must track every candidate window concurrently
  rather than committing to just the first one seen.

`run_timeout_scenario` in `run_tests.sh` covers `--timeout`: launches
`swallow --timeout 1 sleep 5` (a command that never opens a window) and
checks it gives up around 1s, exits non-zero, and leaves the terminal
untouched. All other scenarios explicitly pass `--timeout 30` so they aren't
coupled to how fast a given machine happens to be — only this scenario
should actually race the timeout.

Everything runs against a nested Xephyr display, never the real desktop.

## Conventions

- No comments explaining *what* code does — only *why*, for non-obvious
  constraints (protocol quirks, ICCCM/EWMH semantics, a specific bug a check
  guards against).
- Keep it minimal: no abstractions beyond what's needed, no defensive code
  for cases that can't happen.
