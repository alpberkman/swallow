# swallow

This is a minimal C/X11 CLI tool for Linux. Its target window manager
is Openbox. It launches a GUI app from a terminal. It hides the
terminal while the app's window is open. It restores the terminal's
position and size when the app's window closes. With `--remain`, it
moves the terminal to wherever the app's window ended up instead. With
`--kill`, it closes the terminal instead of restoring it.

This repo also has an independent i3/sway implementation, in
`swallow-i3/`. That is a bash script. It is built on i3/sway IPC,
instead of raw X11. See `swallow-i3/README.md`. `swallow-auto.sh`, at
the root, picks between the two. It picks based on which window
manager is actually running. Callers do not need window-manager-
specific logic of their own. It installs as `swallow-auto`, not
`swallow`; see the `swallow-embed` note below for what `swallow`
itself currently points at. Everything below (build, install, test,
mechanism notes) is about the C tool. The i3/sway script shares no
code and no build system with it.

This repo also has `swallow-wm/`. This is a separate, standalone kiosk
window manager (`mwm`). It has no link to swallow's own hide-and-
restore job. See `swallow-wm/README.md`. It is not covered below.

This repo also has `swallow-embed/`. This is a prototype, independent
of the C tool above: instead of hiding the terminal and creating a
separate window for the app, it reparents the launched app's window
directly into the terminal's own window (`XReparentWindow`), so no new
window is ever created. It shares no code with `swallow-generic.c`,
though it reuses the same "next new top-level window to be created and
mapped" detection approach. See `swallow-embed/README.md`. It has its
own build (`swallow-embed/Makefile`, into `../bin/swallow-embed`) and
its own test (`tests/test-embed.sh`, same throwaway Xephyr+Openbox
pattern as `tests/test-generic.sh`). The top-level `Makefile`'s
`all`/`clean`/`test`/`install`/`uninstall` targets cover it too,
installing the compiled binary as `swallow-embed`. `install` also
symlinks `swallow` (the short command name) straight to
`swallow-embed`, not to `swallow-auto.sh`'s dispatch logic. So right
now, the plain `swallow` command runs this prototype, not the
hide/restore tool documented below or the i3/sway script; those are
still installed, but only reachable as `swallow-generic` and
`swallow-auto`/`swallow-i3` directly. It is still a prototype: it has
no CLI flags of its own yet beyond `-h`/`--help`, and is not covered
below.

## Build / install / test

```
make            # builds bin/swallow-generic (needs pkg-config + libx11-dev)
make test       # builds test helpers (into bin/ too), then runs both suites
make install    # installs to $PREFIX/bin (default ~/.local/bin, no sudo needed)
make clean
```

There is only one source file: `swallow-generic/swallow-generic.c`.
There is no other build system. There is no dependency beyond libX11.
All build outputs land in one top-level `bin/` directory, which is
gitignored. This covers `swallow-generic` itself, and the test helper
binaries under `tests/`. The root `Makefile` delegates the actual
compile step to `swallow-generic/Makefile`. `tests/Makefile` builds
the test helpers directly. Both share the same `../bin`/`bin`
`OUTDIR`.

`install` also copies in `swallow-auto.sh` (as `swallow-auto`) and
`swallow-i3/swallow-i3.sh` (as `swallow-i3`), along with the compiled
binaries (`swallow-generic`, `swallow-embed`). It then symlinks
`swallow` to `swallow-embed` -- see the `swallow-embed` note above.
It also wires `~/.bashrc` for `shell-integration.sh`. It does this
idempotently: an empty `SWALLOW_APPS=()` line, a default
`SWALLOW_FLAGS=...` line, and a `source .../shell-integration.sh`
line. Each line is appended only if no line with that name, or that
exact content, exists yet. So re-running `install` never resets
`SWALLOW_APPS`/`SWALLOW_FLAGS` once you have edited them. It never
duplicates the `source` line either. `uninstall` only removes the
installed commands (`swallow-generic`, `swallow-embed`, `swallow-auto`,
`swallow-i3`, and the `swallow` symlink). It deliberately leaves
`~/.bashrc` alone.

## How it works

- The terminal is whatever window is active (`_NET_ACTIVE_WINDOW`)
  when swallow starts.
- The script treats the launched command's window as "the next new
  top-level window to be created and mapped." It deliberately does not
  match by PID or process tree. Apps like Kate hand off to an
  unrelated, pre-existing process, through D-Bus/kdeinit single-
  instance activation. That process has no link at all to what was
  exec'd.
- `wait_for_target_window()` tracks candidate windows with no explicit
  list. X delivers a self-addressed `MapNotify` (`event == window`)
  only to a client that called `XSelectInput` directly on that window.
  So receiving one already proves it is a window swallow itself
  selected on. This also means every qualifying window is tracked at
  once, not just the first. This matters because some apps (Kate)
  create a non-override-redirect helper window before their real one.
- The terminal is hidden through an unmap (ICCCM Normal to Withdrawn,
  which drops it from the taskbar and pager entirely). It is restored
  through a map, plus explicit geometry reassertion
  (`_NET_MOVERESIZE_WINDOW`), plus `_NET_ACTIVE_WINDOW` focus.
- CLI flags control the placement of the new window. `-x/-y/-w/-l` set
  manual position/size. Use them alone or together. `-d/--default`
  leaves placement to the window manager; this is also the behavior
  with no flags. `-o/--occupy` takes the terminal's exact spot. It
  uses `_NET_FRAME_EXTENTS` to convert between frame size and client
  size. `-f/--full-screen` adds to the others: it is an EWMH state
  layered on top of whatever normal geometry was set, not a
  replacement for it. Run `swallow --help` for the full list.
- Numeric CLI arguments go through `parse_long()`. This function
  rejects non-numeric input, trailing garbage, and `strtol()` overflow
  (`errno == ERANGE`). Without this check, an oversized argument would
  silently become a clamped `LONG_MIN`/`LONG_MAX`. A later `(int)`
  cast would then truncate it into a bogus geometry or timeout,
  instead of an error. `-w`/`-l` also require a positive value, not
  just a non-negative one. X rejects a 0 width or height with
  `BadValue`. The custom error handler swallows that error. So `-w 0`
  would otherwise silently do nothing, instead of raising an error.
- `--occupy` and manual placement apply twice. First, speculatively,
  before the window is mapped: `apply_pre_map_placement()` does this
  from inside `wait_for_target_window()`'s `CreateNotify` handling. It
  uses a raw `XConfigureWindow` call, plus a matching
  `WM_NORMAL_HINTS` `PPosition`/`PSize`. It applies this to every
  candidate window, not just the one that turns out real; see the
  concurrent-tracking note above. This is harmless, since a phantom
  candidate is never mapped. Second, after the window is mapped,
  through the existing `_NET_MOVERESIZE_WINDOW` correction, once
  `target` is known.

  The pre-map call fixes a real, confirmed flash.
  `wait_for_target_window` only returns once `MapNotify` has already
  fired, so the window is already visible by then. An event-trace
  repro (a helper that mirrors `wait_for_target_window`'s own
  `CreateNotify`/`ConfigureNotify` selection logic) showed the target
  actually gets mapped at its own default placement and size first.
  This might be an app's natural default size, or the window
  manager's center/cascade policy. Only a few `ConfigureNotify`s
  later, once the post-map correction lands, does it jump to the
  requested spot. This is the new window's own version of the
  terminal restore flash described further below. Setting the
  geometry before the window is ever mapped uses the same mechanism a
  client uses for its own first-map geometry. So it gets the window
  manager to place the window there directly instead.

  The post-map call stays as a fallback, for window managers that
  ignore the pre-map attempt. This follows the same belt-and-braces
  pattern as the terminal restore. This fix cannot fully remove the
  flash for apps that reposition themselves right before their own
  map, for example with a "center on screen" flag. That case is a
  genuine race against the app's own code. No pre-map trick from a
  third process can reliably win that race. The fix does cover the
  common case: an app that just leaves initial placement to the
  window manager.

- The pre-map fix above covers position. Size needed a separate fix.
  Real toolkit apps (Qt and GTK; confirmed with the same event-trace
  technique against zathura, kate, and pcmanfm) routinely create a
  small window first. They then explicitly resize it to fit their
  content, sometime between `CreateNotify` and their own `XMapWindow`.
  That resize lands after `apply_pre_map_placement()`'s one-shot
  `XConfigureWindow` call, and silently overrides it. So the window
  still mapped at its own natural size first, for example zathura's
  800x600, and only snapped to the requested size an instant later.
  The existing `run_occupy_flash_scenario` test never caught this,
  because it uses `xmessage`. `xmessage` computes its size once, in
  `XCreateWindow` itself, and never re-resizes. So there was nothing
  to race.

  The fix: `apply_pre_map_placement()` now also sets
  `PMinSize`/`PMaxSize`, not just `PSize`, pinned to the same width
  and height. `PSize` alone is only an initial-placement hint the
  window manager consults once. It does not constrain what the app
  itself asks for afterward. Pinning `min == max` instead makes the
  window manager clamp any resize request, including the app's own,
  to that size, for as long as the pin holds. This does not leave the
  window stuck. Apps set their own real `WM_NORMAL_HINTS` (their
  actual minimum size, with no max) shortly after mapping. This
  supersedes the pin, and leaves the window freely resizable again.
  This was confirmed by resizing a swallowed zathura window right
  after launch.

  A reactive alternative was tried and rejected: re-asserting width
  and height on every `ConfigureNotify` up to `MapNotify`, instead of
  a static hint. A/B testing showed this added nothing for zathura and
  pcmanfm. It made kate worse. It forced kate down to the occupy size
  pre-map. Kate then visibly grew back to its real minimum width,
  about 548px, right after mapping. That is a flash the hints-only
  version does not have, since kate settles directly at its true
  minimum before it is ever mapped.

- Known, deliberately unfixed gap: `xterm` still shows a brief pre-map
  size flash, despite the `PMinSize`/`PMaxSize` pin described above.
  An event-trace repro, extended to also log `PropertyNotify` on
  `WM_NORMAL_HINTS` (not just `ConfigureNotify`, which the
  zathura/kate/pcmanfm investigation above used), showed why. xterm
  itself clears `PMinSize`/`PMaxSize` from that property partway
  through its own startup, before it settles on its real, font-
  metric-driven default size and maps. This is unlike the other three
  apps. Their toolkits do not touch `WM_NORMAL_HINTS` again until
  after mapping.

  Reordering `apply_pre_map_placement()`, to set the pin before the
  `XConfigureWindow` call, measured no difference. The theory was that
  the window manager read stale hints when the resize request landed.
  The real cause is xterm overwriting the property itself afterward,
  not read timing. A reactive re-pin, on every such `PropertyNotify`
  up to `MapNotify`, was considered but not attempted. The precedent
  directly above ruled it out: a reactive approach already made kate
  worse, for a related reason. That risk was not worth it, for a flash
  that is entirely pre-map, and so milder than what it targets.
  `run_real_app_occupy_flash_scenario` is accordingly not run against
  xterm in `test-generic.sh`. Only the main hide/restore/geometry
  scenario is. So this known gap does not show up as a repeat test
  failure.

- `-t/--timeout <n>` bounds `wait_for_target_window()`. Its default is
  3 seconds. `0` waits forever. Finite values are capped at 3600
  seconds. It uses `poll()` on the X connection file descriptor
  (`ConnectionNumber(dpy)`). It does not use `select()`, and it does
  not use a sleep-poll loop. Both alternatives were tried. It is worth
  knowing not to bring them back. A sleep-poll loop, draining
  `XPending()` then `usleep()`-ing between checks, reliably failed to
  ever detect the target window's events in testing. It even crashed a
  nested Xephyr server under repeated use. Blocking directly on the
  connection file descriptor is required, not just "nicer." The
  3600-second cap on finite values (0, meaning unlimited, is exempt)
  keeps `remaining * 1000`, in `wait_for_target_window()`'s
  `poll()`-timeout conversion, well clear of `int` overflow. A raw,
  unbounded `-t` would otherwise risk this, for values past about 24.8
  days.

- `-r/--remain`: instead of restoring the terminal's own original
  geometry on close, `wait_for_window_close()` tracks the target
  window's on-screen frame geometry, and its own `_NET_FRAME_EXTENTS`,
  as they change. It re-derives both, using `get_window_geometry()`
  and `get_frame_extents()` (the same reparenting-aware helpers used
  for the terminal), on every `ConfigureNotify` the target gets. It
  has to do this, since by the time `DestroyNotify` fires, the window
  is gone and can no longer be queried. `wait_for_window_close()`
  itself still just blocks on `XNextEvent()` with no timeout, unlike
  `wait_for_target_window()`. There is no equal failure mode to guard
  against here: the window already exists, and waiting for it to close
  is the whole point. So no `poll()` or `select()` is needed.

  Converting the target's last frame size into a client-size request
  for the terminal must use the target's own insets, not the
  terminal's. Using the terminal's insets only happens to cancel out
  when both windows share identical decorations. When they do not, for
  example under different theming rules, or with an undecorated
  target, which is common with per-app Openbox `<application>` rules,
  the wrong-insets version does more than misplace one restore.
  `--occupy`'s own placement of the target was itself sized off of the
  terminal's previous geometry. So the wrong-insets version feeds a
  slightly wrong size back as the terminal's reference geometry for
  the next invocation. This compounds by a fixed amount on every
  single `--occupy --remain` cycle, with no fixed point. This was
  confirmed with a rigged Openbox rule that stripped a target's
  decorations. The terminal drifted by a constant delta indefinitely
  with the terminal's own insets. It stayed perfectly stable with the
  target's own insets.

- Restoring the terminal calls `XMoveResizeWindow()` directly on it,
  before `XMapWindow`. This fixes a real, confirmed flash and jump on
  restore. An event-trace repro (a helper that selects
  `StructureNotify` on the terminal and logs every
  `ConfigureNotify`/`MapNotify` with a timestamp) showed why. Openbox
  remaps a withdrawn window straight back to whatever geometry it
  remembers from before the unmap. It ignores both a `PPosition`
  `WM_NORMAL_HINTS` hint, and a pre-map `_NET_MOVERESIZE_WINDOW`
  client message. That message is an EWMH request for repositioning
  an already-mapped window, for example a pager dragging one around.
  Openbox appears to just ignore it while the window is withdrawn.
  Openbox then jumps the window again a few milliseconds later, once
  the post-map correction lands.

  A raw `XMoveResizeWindow` uses the same mechanism a client uses to
  set its own geometry before its first-ever map. So Openbox picks it
  up as the window's current geometry, and remaps it straight there.
  `XSync` follows it. So this is confirmed applied before
  `XMapWindow`.

- Restoring the terminal also sets a `PPosition` `WM_NORMAL_HINTS`
  hint. It does this through a read-modify-write with
  `XGetWMNormalHints`/`XSetWMNormalHints`, which preserves any other
  hints already present, before `XMapWindow`. This is belt-and-braces
  alongside the `XMoveResizeWindow` call above, for window managers
  that behave differently from Openbox: ones that do forget geometry
  on withdraw, and run a real placement policy (cascade, center,
  smart, or similar) on remap. For those, the hint is what makes them
  honor the restored position instead of overriding it.

  This hint is deliberately position-only. It is never `PSize` or
  width/height. A remap is treated like a fresh initial map. So a size
  hint gets run back through the window's own
  `PResizeInc`/`PBaseSize`, for example a terminal's character-cell
  size, and rounded down to the nearest valid increment. That would
  shrink the window a little on every restore. Size stays the job of
  the already-correct `_NET_MOVERESIZE_WINDOW` fallback, sent right
  after `XMapWindow`, which does not have that problem.

- `-k/--kill` skips the entire restore path above. Instead, it calls
  `close_window()` on the terminal. That sends a `WM_DELETE_WINDOW`
  `ClientMessage` straight to the window: the same protocol message
  `wmctrl -c`, and a window manager's own close button, use. It is not
  the EWMH `_NET_CLOSE_WINDOW` request. It is not routed through
  `send_client_message()` either (which targets root, with
  `SubstructureRedirectMask`; that is the convention for asking the
  window manager to act on a window).

  By the time this runs, `term_win` has already been through
  `XUnmapWindow`, earlier in `main()`, for the hide step. ICCCM Normal
  to Withdrawn means the window manager has reparented it back under
  root, and dropped its managed frame. So a request that relies on the
  window manager still tracking it as managed, such as
  `_NET_CLOSE_WINDOW`, or `send_client_message()`'s own root-directed
  convention, silently does nothing at that point. This was confirmed
  with a real Xephyr+Openbox repro. Both the window and the terminal
  process outlived it indefinitely.

  Sending `WM_DELETE_WINDOW` directly to the window sidesteps the
  window manager entirely. It is just a `ClientMessage` the app itself
  watches for. This is valid whether or not the window manager
  currently manages the window. `close_window()` gates this on
  `XGetWMProtocols()` showing that the terminal actually advertises
  `WM_DELETE_WINDOW` support first. This is still a request, not a
  forced kill. A compliant terminal can decline it, for example to
  prompt on unsaved output, the same as clicking its own close button
  would. `XKillClient()` is the fallback, for a terminal that never
  registered the protocol at all. This is the same fallback EWMH
  itself documents for `_NET_CLOSE_WINDOW`. This is rejected in
  combination with `--remain`: `--remain` only controls where the
  terminal is restored to, which does not matter once the terminal is
  closed instead of restored.

## Testing

`tests/test-generic.sh` is a real integration suite, not a set of unit
tests. It spins up a throwaway Xephyr and Openbox session. It drives
that session with `xdotool`/`xprop`. It requires `Xephyr`, `openbox`,
`xdotool`, and `xprop`. The script skips cleanly (exit 0) if they are
missing. It also opportunistically tests against real apps (`zathura`,
`kate`, `pcmanfm`, `xterm`) if they are installed, and skips those
specific scenarios otherwise.

Test helper binaries live in `tests/`. They simulate specific
real-world launch patterns:
- `fork_exec_helper.c`: a fork+exec launcher, in the double-fork
  daemonize style.
- `phantom_window_helper.c`: creates a never-mapped decoy window,
  before it execs the real command. This reproduces the Kate-style
  case, where a non-override-redirect helper window appears first.
  This is the regression test for why `wait_for_target_window` must
  track every candidate window at once, rather than commit to just the
  first one seen.

`run_timeout_scenario`, in `test-generic.sh`, covers `--timeout`. It
launches `swallow --timeout 1 sleep 5`, a command that never opens a
window. It checks that swallow gives up around 1 second later, exits
non-zero, and leaves the terminal untouched. All other scenarios
explicitly pass `--timeout 30`. So they do not depend on how fast a
given machine happens to be. Only this scenario should actually race
the timeout.

`run_remain_scenario` covers `--remain`. It launches `swallow
--remain` against an app window. It moves and resizes that window,
standing in for the user repositioning it while they work, then
closes it. It then checks that the terminal ends up at the app's last
geometry, not its own original spot.

`run_kill_scenario` covers `--kill`. It launches `swallow --kill`
against an app window. It closes that window, then checks that the
terminal process itself exited, and its window is gone, rather than
being restored. This is the regression test for the
`_NET_CLOSE_WINDOW`-goes-nowhere bug described above. It initially
failed exactly that way: the window and the process both survived.
The fix switched to a direct `WM_DELETE_WINDOW` message.

`run_occupy_flash_scenario` covers the position pre-map flash, using
`xmessage`. `run_real_app_occupy_flash_scenario` covers the size one.
It is opportunistic: it runs against zathura, kate, or pcmanfm,
whichever are installed. Unlike the xmessage-based test, it does not
fail on seeing more than one distinct pre-map size. A real app's own
pre-map resize churn is expected and harmless, since the window is not
mapped yet. It fails only if the size the window is actually mapped at
differs from the size it later settles at. That would mean a real,
visible post-map jump. This was verified to actually catch the bug it
targets, by reverting the `PMinSize`/`PMaxSize` fix and confirming
that the test then fails (zathura: mapped at 798x577, settled at
496x342). So this is not just theater that passes regardless. This
test is not run against xterm, which also gets a plain
`run_real_app_scenario`; see the known xterm flash gap noted above,
under `apply_pre_map_placement()`.

Everything runs against a nested Xephyr display, never the real
desktop.

## Conventions

- Do not write comments that explain what code does. Write comments
  only for why: non-obvious constraints, protocol quirks, ICCCM/EWMH
  semantics, or a specific bug that a check guards against.
- Keep the code minimal. Do not add abstractions beyond what is
  needed. Do not add defensive code for cases that cannot happen.
