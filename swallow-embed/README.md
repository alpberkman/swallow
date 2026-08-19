# swallow-embed

Prototype. Reparents a launched app's window into the window that is
currently active (`_NET_ACTIVE_WINDOW`, normally the terminal this ran
from), via `XReparentWindow`, on the same X display. No new window is
created.

## How it works

- Finds the active window (`term_win`).
- Selects `SubstructureNotify` on root, launches `<command>`, and
  tracks "the next new top-level window to be created and mapped" the
  same way `swallow-generic.c` does: candidate `CreateNotify` windows,
  a self-addressed `MapNotify`, not by PID.
- Marks each candidate `override_redirect` before it maps. Without
  this, the real WM (i3, Openbox, ...) still holds
  `SubstructureRedirectMask` on root and always wins the race to
  reparent the window into its own decoration frame first, and nothing
  gets embedded.
- Reparents the found window into `term_win`, resizes it to fill,
  maps it, focuses it.
- Ctrl+Q sends the embedded app `WM_DELETE_WINDOW`.
- While running, `term_win` is also watched for `ConfigureNotify`: if
  it gets resized, the embedded app is resized to match.

## Known gaps

- Apps that create their own throwaway probe window before their real
  one (confirmed: `lxterminal`'s D-Bus single-instance handshake) can
  get the probe embedded instead of the real window.
- No flags (geometry, `--kill`, timeout). Not wired into
  `swallow-auto.sh` or the top-level `Makefile`.

## Build

```sh
make
```

Builds `../bin/swallow-embed`.

## Usage

```sh
swallow-embed <command> [args...]
```

Run from the terminal you want the app embedded into.

## Test

```sh
../tests/test-embed.sh
```

Same throwaway Xephyr+openbox pattern as `test-generic.sh`.
