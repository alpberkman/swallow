# swallow

A minimal C/X11 CLI tool for Linux (target WM: Openbox). It launches a GUI
app from a terminal, hides the terminal while the app's window is open, and
restores the terminal (position + size) when the app's window closes — or,
with `--remain`, moves the terminal to wherever the app's window ended up
instead, or, with `--kill`, closes the terminal instead of restoring it.

This repo also has an independent i3/sway-specific implementation in
`swallow-i3/` (a bash script built on i3/sway IPC instead of raw X11 — see
`swallow-i3/README.md`), and `swallow-auto.sh` at the root, which picks
between the two based on which WM is actually running so callers don't
need WM-specific logic of their own. Everything below (build/install/test,
mechanism notes) is about the C tool; the i3/sway script doesn't share
code or a build system with it.

## Build / install / test

```
make            # builds bin/swallow (needs pkg-config + libx11-dev)
make test       # builds test helpers (into bin/ too), then runs the suite
make install    # installs to $PREFIX/bin (default ~/.local/bin, no sudo needed)
make clean
```

There is only one source file: `src/swallow.c`. No other build system, no
dependencies beyond libX11. All build outputs (`swallow` itself and the test
helper binaries under `tests/`) land in a single top-level `bin/` directory,
gitignored, built by both `Makefile` and `tests/Makefile` via a shared
`../bin`/`bin` `OUTDIR`.

`install` also copies in `swallow-auto.sh` (as `swallow-auto`) and
`swallow-i3/swallow-i3.sh` (as `swallow-i3`) alongside the compiled
binary, and idempotently wires `~/.bashrc` for `shell-integration.sh`: an
empty `SWALLOW_APPS=()` line, a default `SWALLOW_FLAGS=...` line, and a
`source .../shell-integration.sh` line, each appended only if no line
with that name/exact content already exists -- so re-running `install`
never resets `SWALLOW_APPS`/`SWALLOW_FLAGS` once you've edited them, and
never duplicates the `source` line. `uninstall` only removes the three
installed commands; it deliberately leaves `~/.bashrc` alone.

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
- The above covers *position*; *size* needed a separate fix. Real toolkit
  apps (Qt/GTK — confirmed via the same event-trace technique against
  zathura, kate, pcmanfm) routinely create small and then explicitly resize
  themselves to fit their content sometime between `CreateNotify` and their
  own `XMapWindow` — landing after `apply_pre_map_placement()`'s one-shot
  `XConfigureWindow` and silently overriding it, so the window still mapped
  at its own natural size first (e.g. zathura's 800×600) and only snapped to
  the requested size an instant later. The existing `run_occupy_flash_scenario`
  test never caught this because it uses `xmessage`, which computes its size
  once in `XCreateWindow` itself and never re-resizes — nothing to race. The
  fix: `apply_pre_map_placement()` now sets `PMinSize`/`PMaxSize` (not just
  `PSize`) pinned to the same width/height. `PSize` alone is only an
  initial-placement hint the WM consults once; it doesn't constrain what the
  app itself asks for afterward. Pinning `min == max` instead makes the WM
  clamp *any* resize request — the app's own included — to that size for as
  long as the pin holds. It doesn't leave the window stuck: apps set their
  own real `WM_NORMAL_HINTS` (their actual minimum size, no max) shortly
  after mapping, superseding the pin and leaving the window freely resizable
  again (confirmed by resizing a swallowed zathura window right after
  launch). A reactive alternative — re-asserting width/height on every
  `ConfigureNotify` up to `MapNotify` instead of a static hint — was tried
  and rejected: A/B testing showed it added nothing for zathura/pcmanfm and
  made kate *worse* (forces it down to the occupy size pre-map, then it
  visibly grows back to its real ~548px minimum width right after mapping,
  a flash the hints-only version doesn't have since kate settles directly at
  its true minimum before ever being mapped).
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
- `-k/--kill`: skips the entire restore path above and instead calls
  `close_window()` on the terminal. That's a `WM_DELETE_WINDOW`
  `ClientMessage` sent straight to the window (the same protocol message
  `wmctrl -c` and a WM's own close button use), not the EWMH
  `_NET_CLOSE_WINDOW` request, and not routed through `send_client_message()`
  (root + `SubstructureRedirectMask`, the convention for asking the *WM* to
  act on a window) — by the time this runs, `term_win` has already been
  through `XUnmapWindow` earlier in `main()` for the hide step, and ICCCM
  Normal → Withdrawn means the WM has reparented it back under root and
  dropped its managed frame, so a request that relies on the WM still
  tracking it as managed (`_NET_CLOSE_WINDOW`, or `send_client_message()`'s
  own root-directed convention) silently does nothing at that point —
  confirmed via a real Xephyr+Openbox repro: both the window and the
  terminal process outlived it indefinitely. Sending `WM_DELETE_WINDOW`
  directly to the window sidesteps the WM entirely: it's just a
  `ClientMessage` the app itself watches for, valid whether or not the WM
  currently manages the window. `close_window()` gates this on
  `XGetWMProtocols()` showing the terminal actually advertises
  `WM_DELETE_WINDOW` support first — still a request, not a forced kill, so
  a compliant terminal can decline (e.g. prompt on unsaved output), same as
  clicking its own close button would. `XKillClient()` is the fallback for
  a terminal that never registered the protocol at all (same fallback EWMH
  itself documents for `_NET_CLOSE_WINDOW`). Rejected in combination with
  `--remain`: `--remain` only controls where the terminal is restored to,
  which is moot once it's closed instead of restored.

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

`run_kill_scenario` covers `--kill`: launches `swallow --kill` against an
app window, closes it, then checks the terminal process itself exited and
its window is gone, rather than being restored. This is the regression
test for the `_NET_CLOSE_WINDOW`-goes-nowhere bug above — it initially
failed exactly that way (window and process both survived) until the fix
switched to a direct `WM_DELETE_WINDOW` message.

`run_occupy_flash_scenario` covers the *position* pre-map flash, using
`xmessage`. `run_real_app_occupy_flash_scenario` (opportunistic, zathura/kate
only) covers the *size* one: unlike the xmessage-based test, it doesn't fail
on seeing more than one distinct pre-map size (a real app's own pre-map
resize churn is expected and harmless, since the window isn't mapped yet) —
it fails only if the size the window is *actually mapped at* differs from
the size it later settles at, i.e. a real, visible post-map jump. Verified
to actually catch the bug it targets by reverting the `PMinSize`/`PMaxSize`
fix and confirming it fails (zathura: mapped at 798×577, settled at
496×342) — not just theater that passes regardless.

Everything runs against a nested Xephyr display, never the real desktop.

## Conventions

- No comments explaining *what* code does — only *why*, for non-obvious
  constraints (protocol quirks, ICCCM/EWMH semantics, a specific bug a check
  guards against).
- Keep it minimal: no abstractions beyond what's needed, no defensive code
  for cases that can't happen.
