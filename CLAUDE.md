# swallow

A minimal C/X11 CLI tool for Linux (target WM: Openbox). It launches a GUI
app from a terminal, hides the terminal while the app's window is open, and
restores the terminal (position + size) when the app's window closes — or,
with `--remain`, moves the terminal to wherever the app's window ended up
instead.

## Build / install / test

```
make            # builds bin/swallow (needs pkg-config + libx11-dev)
make test       # builds test helpers (into bin/ too), then runs the suite
make install    # installs to $PREFIX/bin (default /usr/local/bin)
make clean
```

There is only one source file: `src/swallow.c`. No other build system, no
dependencies beyond libX11. All build outputs (`swallow` itself and the test
helper binaries under `tests/`) land in a single top-level `bin/` directory,
gitignored, built by both `Makefile` and `tests/Makefile` via a shared
`../bin`/`bin` `OUTDIR`.

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
- That placement (`--occupy`/manual) is applied *twice*: once speculatively
  pre-map, by `apply_pre_map_placement()` from inside
  `wait_for_target_window()`'s `CreateNotify` handling (raw
  `XConfigureWindow` plus a matching `WM_NORMAL_HINTS` `PPosition`/`PSize`,
  applied to every candidate window, not just the eventual real one — see
  the concurrent-tracking note above, harmless since a phantom candidate is
  never mapped), and again post-map via the existing
  `_NET_MOVERESIZE_WINDOW` correction once `target` is known. The pre-map
  call is the fix for real, confirmed flash: `wait_for_target_window` only
  returns once `MapNotify` has already fired, i.e. the window is already
  visible — an event-trace repro (a helper mirroring
  `wait_for_target_window`'s own `CreateNotify`/`ConfigureNotify` selection
  logic) showed the target actually gets mapped at its own default
  placement/size first (e.g. an app's natural default size, or the WM's
  center/cascade policy) and only jumps to the requested spot a few
  `ConfigureNotify`s later, once the post-map correction lands — the new
  window's own equivalent of the terminal restore flash below. Setting the
  geometry before the window is *ever* mapped — the same mechanism a client
  uses for its own first-map geometry — gets the WM to place it there
  directly instead. The post-map call stays as a fallback for WMs that
  ignore the pre-map attempt, same belt-and-braces pattern as the terminal
  restore. This can't fully eliminate the flash for apps that explicitly
  reposition themselves right before their own map (e.g. a "center on
  screen" flag) — that's a genuine race against the app's own code that no
  pre-map trick from a third process can reliably win — but it does for the
  common case of an app that just leaves initial placement to the WM.
- `-t/--timeout <n>` (default 3s, 0 waits forever) bounds
  `wait_for_target_window()`: `poll()` on the X connection fd
  (`ConnectionNumber(dpy)`), not `select()` or a sleep-poll loop — both
  alternatives were tried and are worth knowing not to reintroduce. A
  sleep-poll loop (draining `XPending()` then `usleep()`-ing between checks)
  reliably failed to ever detect the target window's events in testing and
  even crashed a nested Xephyr server under repeated use; blocking directly
  on the connection fd is required, not just "nicer."
- `-r/--remain`: instead of restoring the terminal's own original geometry
  on close, `wait_for_window_close()` tracks the target window's on-screen
  frame geometry *and* its own `_NET_FRAME_EXTENTS` as they change —
  re-deriving both via `get_window_geometry()`/`get_frame_extents()` (the
  same reparenting-aware helpers used for the terminal) on every
  `ConfigureNotify` the target gets, since by the time `DestroyNotify` fires
  the window is gone and can't be queried anymore. `wait_for_window_close()`
  itself still just blocks on `XNextEvent()` with no timeout, unlike
  `wait_for_target_window()` — there's no equivalent failure mode to guard
  against here (the window already exists; waiting for it to close is the
  whole point), so no `poll()`/`select()` is needed.
  - Converting the target's last frame size into a client-size request for
    the terminal **must** use the target's own insets, not the terminal's.
    Using the terminal's insets only happens to cancel out when both windows
    share identical decorations; when they don't (different theming rules,
    an undecorated target, etc. — common with per-app Openbox `<application>`
    rules), `--occupy`'s own placement of the target was itself sized off of
    the terminal's *previous* geometry, so the wrong-insets version doesn't
    just misplace one restore — it feeds a slightly wrong size back as the
    terminal's reference geometry for the *next* invocation, compounding by a
    fixed amount every single `--occupy --remain` cycle with no fixed point
    (confirmed via a rigged Openbox rule stripping a target's decorations:
    drifted by a constant delta indefinitely with the terminal's insets,
    perfectly stable with the target's own).
- Restoring the terminal calls `XMoveResizeWindow()` directly on it *before*
  `XMapWindow`. This is the fix for a real, confirmed flash/jump on restore:
  an event-trace repro (a helper selecting `StructureNotify` on the terminal
  and logging every `ConfigureNotify`/`MapNotify` with a timestamp) showed
  Openbox remaps a withdrawn window straight back to whatever geometry it
  remembers from before the unmap — ignoring both a `PPosition`
  `WM_NORMAL_HINTS` hint and a pre-map `_NET_MOVERESIZE_WINDOW` client
  message (that message is an EWMH request for repositioning an
  *already-mapped* window, e.g. a pager dragging one around, and Openbox
  appears to just ignore it while withdrawn) — then jumping again a few ms
  later once the post-map correction landed. A raw `XMoveResizeWindow` is
  the same mechanism a client uses to set its own geometry before its
  *first-ever* map, so Openbox picks it up as the window's current geometry
  and remaps it straight there. `XSync` follows it so this is confirmed
  applied before `XMapWindow`.
- Restoring the terminal *also* sets a `PPosition` `WM_NORMAL_HINTS` hint
  (read-modify-write via `XGetWMNormalHints`/`XSetWMNormalHints`, preserving
  any other hints already present) before `XMapWindow`, belt-and-braces
  alongside the `XMoveResizeWindow` call above for WMs that behave
  differently from Openbox — ones that *do* forget geometry on withdraw and
  run a real placement policy (cascade/center/smart/etc.) on remap, where
  the hint is what makes them honor the restored position instead of
  overriding it. Deliberately position-only, never `PSize`/width/height: a
  remap is treated like a fresh initial map, so a size hint gets run back
  through the window's own `PResizeInc`/`PBaseSize` (e.g. a terminal's
  character-cell size) and rounded down to the nearest valid increment,
  shrinking it a little on every restore. Size stays the job of the
  (already-correct) `_NET_MOVERESIZE_WINDOW` fallback sent right after
  `XMapWindow`, which doesn't have that problem.

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

`run_remain_scenario` covers `--remain`: launches `swallow --remain` against
an app window, moves/resizes that window (standing in for the user
repositioning it while they work) before closing it, then checks the
terminal ends up at the app's last geometry rather than its own original
spot.

Everything runs against a nested Xephyr display, never the real desktop.

## Conventions

- No comments explaining *what* code does — only *why*, for non-obvious
  constraints (protocol quirks, ICCCM/EWMH semantics, a specific bug a check
  guards against).
- Keep it minimal: no abstractions beyond what's needed, no defensive code
  for cases that can't happen.
