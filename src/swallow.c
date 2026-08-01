/*
 * swallow -- run a GUI app from a terminal, hide the terminal while the
 * app's window is open, and restore it when the app closes.
 *
 * Usage: swallow <command> [args...]
 *
 * The terminal is whatever window is active (_NET_ACTIVE_WINDOW) when
 * swallow starts. The launched command's window is the next new top-level
 * window created and mapped -- not matched by PID, since many apps hand
 * the real work off to an unrelated process (fork+exec launchers,
 * double-fork daemonizing, or D-Bus/kdeinit single-instance activation
 * handing off to an already-running process, e.g. Kate).
 *
 * Placement follows --x/--y/--width/--length/--default/--occupy/
 * --full-screen (see --help): applied speculatively before the window is
 * even mapped (see apply_pre_map_placement), then again as a fallback once
 * it's confirmed as the real target, so it never visibly appears anywhere
 * but the requested spot. Default (no flags) leaves placement to the WM.
 * If no window appears within --timeout seconds (default 3), swallow exits
 * without ever hiding the terminal.
 *
 * The terminal is hidden via unmap (ICCCM Normal -> Withdrawn, which drops
 * it from the taskbar/pager, unlike iconify) and restored via map, with its
 * geometry reasserted (withdrawing forgets it, so the WM's placement policy
 * would otherwise relocate/resize it) and focus returned via
 * _NET_ACTIVE_WINDOW. Restored geometry is normally the terminal's own
 * original spot; with --remain it's wherever the app's window last was;
 * with --kill the terminal is closed instead of restored.
 */

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <poll.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_TIMEOUT_SEC 3
#define MAX_TIMEOUT_SEC 3600

#define CWXY (CWX | CWY)
#define CWWH (CWWidth | CWHeight)

static const struct option long_opts[] = {
    {"x", required_argument, NULL, 'x'},
    {"y", required_argument, NULL, 'y'},
    {"width", required_argument, NULL, 'w'},
    {"length", required_argument, NULL, 'l'},
    {"timeout", required_argument, NULL, 't'},
    {"default", no_argument, NULL, 'd'},
    {"occupy", no_argument, NULL, 'o'},
    {"full-screen", no_argument, NULL, 'f'},
    {"remain", no_argument, NULL, 'r'},
    {"kill", no_argument, NULL, 'k'},
    {"help", no_argument, NULL, 'h'},
    {NULL, 0, NULL, 0},
};

static void usage(const char *prog) {
    printf(
        "usage: %s [options] <command> [args...]\n"
        "\n"
        "Options (affect only where/how the windows are placed):\n"
        "  -x, --x <n>        X position for the new window\n"
        "  -y, --y <n>        Y position for the new window\n"
        "  -w, --width <n>    Width for the new window\n"
        "  -l, --length <n>   Height for the new window\n"
        "  -d, --default      Let the window manager choose size/position (the default)\n"
        "  -o, --occupy       Make the new window occupy the terminal's exact spot\n"
        "  -f, --full-screen  Start the new window full-screen\n"
        "  -t, --timeout <n>  Give up if no window appears within n seconds\n"
        "                     (default %d; 0 waits forever; capped at %d)\n"
        "  -r, --remain       When the app's window closes, put the terminal where\n"
        "                     that window ended up instead of restoring the\n"
        "                     terminal's original position/size\n"
        "  -k, --kill         When the app's window closes, close the terminal\n"
        "                     instead of restoring it\n"
        "  -h, --help         Show this help and exit\n"
        "\n"
        "--default and --occupy are mutually exclusive.\n"
        "--x/--y/--width/--length may be used individually or together to place\n"
        "the window manually; any not given are left to the app/WM. They cannot be\n"
        "combined with --occupy, which already determines the full geometry itself.\n"
        "--full-screen can be used with any other flags since they set the actual geometry,\n"
        "while full screen is more like a special view.\n"
        "--kill and --remain are mutually exclusive.\n",
        prog, DEFAULT_TIMEOUT_SEC, MAX_TIMEOUT_SEC);
}

/* strtol(), but rejecting anything not *entirely* numeric -- including "",
 * which strtol accepts as 0 (endptr == s == '\0', so a bare `*end != '\0'`
 * check alone lets it through) -- and anything out of range for long, which
 * strtol reports via errno rather than *end (end still lands on '\0' since
 * the whole string was consumed, just clamped to LONG_MIN/LONG_MAX). Left
 * unchecked, an out-of-range value would silently become a bogus geometry
 * or timeout once truncated by a later (int) cast, instead of an error. */
static int parse_long(const char *s, long *out) {
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if(end == s || *end != '\0' || errno == ERANGE)
        return 0;
    *out = v;
    return 1;
}

/* Falls back to fallback when v isn't positive -- guards against a computed
 * client size (frame size minus decoration insets) coming out <= 0, e.g.
 * from stale/mismatched frame extents. */
static int clamp_positive(int v, int fallback) {
    return v > 0 ? v : fallback;
}

static int x_error_handler(Display *dpy, XErrorEvent *e) {
    (void)dpy;
    (void)e;
    return 0; /* don't let a stray error kill us */
}

static Window get_active_window(Display *dpy, Window root, Atom net_active_window) {
    Atom type;
    int format;
    unsigned long nitems, after;
    unsigned char *prop = NULL;
    Window result = None;

    if(XGetWindowProperty(dpy, root, net_active_window, 0, 1, False, XA_WINDOW,
                            &type, &format, &nitems, &after, &prop) == Success) {
        if(prop) {
            if(nitems >= 1) result = *(Window *)prop;
            XFree(prop);
        }
    }
    return result;
}

static void send_client_message(Display *dpy, Window target, Window root, Atom type,
                                 long l0, long l1, long l2, long l3, long l4) {
    XEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.xclient.type = ClientMessage;
    ev.xclient.window = target;
    ev.xclient.message_type = type;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = l0;
    ev.xclient.data.l[1] = l1;
    ev.xclient.data.l[2] = l2;
    ev.xclient.data.l[3] = l3;
    ev.xclient.data.l[4] = l4;
    XSendEvent(dpy, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &ev);
}

/* Closes win via WM_DELETE_WINDOW sent directly to it (what wmctrl -c and a
 * WM's own close button use) -- not send_client_message's root/
 * SubstructureRedirect convention, which asks the *WM* to act on a window
 * (e.g. _NET_CLOSE_WINDOW) and silently does nothing here: by the time
 * --kill calls this, win has already been unmapped (ICCCM Normal->
 * Withdrawn) and the WM no longer manages it (confirmed: window and process
 * both survived indefinitely with _NET_CLOSE_WINDOW). Gated on win
 * advertising WM_DELETE_WINDOW via WM_PROTOCOLS -- a request, not a forced
 * kill, so a compliant client can decline (e.g. prompt on unsaved output).
 * XKillClient is the fallback for a client that never registered the
 * protocol, same as _NET_CLOSE_WINDOW's own documented fallback. */
static void close_window(Display *dpy, Window win, Atom wm_protocols, Atom wm_delete_window) {
    Atom *protocols = NULL;
    int nprotocols = 0;
    int supports_delete = 0;
    if(XGetWMProtocols(dpy, win, &protocols, &nprotocols)) {
        for(int i = 0; i < nprotocols; i++) {
            if(protocols[i] == wm_delete_window) { supports_delete = 1; break; }
        }
        XFree(protocols);
    }
    if(supports_delete) {
        XEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.xclient.type = ClientMessage;
        ev.xclient.window = win;
        ev.xclient.message_type = wm_protocols;
        ev.xclient.format = 32;
        ev.xclient.data.l[0] = (long)wm_delete_window;
        ev.xclient.data.l[1] = CurrentTime;
        XSendEvent(dpy, win, False, NoEventMask, &ev);
    } else {
        XKillClient(dpy, win);
    }
}

/* Root-relative screen geometry of win, using its decoration frame (the WM
 * reparents managed windows one level under root) if it has one. Fills
 * attrs in place rather than separate out-params, since that's already the
 * exact struct XGetWindowAttributes produces -- only .x/.y/.width/.height
 * matter here. Zeroed unconditionally first since XGetWindowAttributes
 * leaves attrs untouched (not zeroed) on failure. */
static void get_window_geometry(Display *dpy, Window win, Window root,
                                 XWindowAttributes *attrs) {
    Window r, parent, *children = NULL;
    unsigned int nchildren = 0;
    Window target = win;

    if(XQueryTree(dpy, win, &r, &parent, &children, &nchildren)) {
        if(children)
            XFree(children);
        if(parent != None && parent != root)
            target = parent;
    }

    memset(attrs, 0, sizeof(*attrs));
    XGetWindowAttributes(dpy, target, attrs);
}

/* Indices into a frame_extents_t, in the same order the _NET_FRAME_EXTENTS
 * property itself uses: CARDINAL[4] left, right, top, bottom. */
enum { EXT_LEFT, EXT_RIGHT, EXT_TOP, EXT_BOTTOM };
typedef int frame_extents_t[4];

/* win's decoration insets (_NET_FRAME_EXTENTS): how much smaller its client
 * area is than its full on-screen footprint. All zero if unpublished (e.g.
 * undecorated). frame_extents_t rather than 4 out-params since that's the
 * property's own wire shape (CARDINAL[4]), with no per-field names in the
 * protocol to justify a named-field struct. */
static void get_frame_extents(Display *dpy, Window win, Atom net_frame_extents,
                               frame_extents_t extents) {
    Atom type;
    int format;
    unsigned long nitems, after;
    unsigned char *prop = NULL;
    extents[EXT_LEFT] = extents[EXT_RIGHT] = extents[EXT_TOP] = extents[EXT_BOTTOM] = 0;

    if(XGetWindowProperty(dpy, win, net_frame_extents, 0, 4, False, XA_CARDINAL,
                            &type, &format, &nitems, &after, &prop) == Success) {
        if(prop) {
            if(nitems == 4) {
                long *vals = (long *)prop;
                extents[EXT_LEFT] = (int)vals[EXT_LEFT];
                extents[EXT_RIGHT] = (int)vals[EXT_RIGHT];
                extents[EXT_TOP] = (int)vals[EXT_TOP];
                extents[EXT_BOTTOM] = (int)vals[EXT_BOTTOM];
            }
            XFree(prop);
        }
    }
}

/* Geometry to speculatively apply to every create-notified candidate window
 * before the app itself maps it -- see below. mask uses XConfigureWindow's
 * CWX/CWY/CWWidth/CWHeight bits, mirroring -x/-y/-w/-l being usable
 * individually; a zero mask means no pre-map placement (--default, or no
 * placement flags). Carried as an XWindowChanges + mask pair since that's
 * exactly what XConfigureWindow itself needs.
 *
 * Applied to every qualifying candidate as soon as it's created, not just
 * the confirmed target -- which candidate is real isn't known until
 * MapNotify (see wait_for_target_window), and applying this to a phantom
 * window that never maps is harmless.
 *
 * Pre-map analogue of the terminal restore's XMoveResizeWindow trick, for
 * the same reason: an event-trace repro showed the target actually maps at
 * the WM's own default placement first and only jumps to the requested spot
 * a few ConfigureNotify events later, once the post-map
 * _NET_MOVERESIZE_WINDOW correction lands -- a visible flash. Setting
 * geometry before the window is ever mapped, the same mechanism a client
 * uses for its own first-map geometry, gets the WM to place it there
 * immediately instead.
 *
 * XConfigureWindow (not XMoveResizeWindow) since it can set a subset of
 * x/y/width/height, needed when only some axes are given. WM_NORMAL_HINTS
 * is set alongside for WMs that honor the hint but not a bare geometry
 * change on an unmapped window -- only when a full pair (x+y or w+h) is
 * given, since PPosition/PSize apply to both axes of a pair at once.
 *
 * Hints are set *before* XConfigureWindow, not after: confirmed via a real
 * xterm repro that the order matters. Unlike zathura/kate/pcmanfm (whose
 * toolkits don't have resize-increment hints in place this early), xterm
 * sets its own WM_NORMAL_HINTS (PResizeInc/PBaseSize, its character-cell
 * grid) essentially at creation -- so if XConfigureWindow's resulting
 * ConfigureRequest reaches the WM before our own PMinSize/PMaxSize pin
 * does, the WM still only knows about xterm's grid hints and rounds our
 * requested size down to the nearest valid cell size, one map-then-jump
 * flash before the pin catches up. Sending the pin first means the WM
 * already has it in hand -- min==max leaves no room for grid rounding --
 * by the time it processes the resize. */
static void apply_pre_map_placement(Display *dpy, Window win, XWindowChanges wc, unsigned int mask) {
    if(!mask)
        return;

    if((mask & CWXY) == CWXY || (mask & CWWH) == CWWH) {
        XSizeHints hints;
        long supplied;
        if(!XGetWMNormalHints(dpy, win, &hints, &supplied))
            hints.flags = 0;
        if((mask & CWXY) == CWXY) {
            hints.flags |= PPosition;
            hints.x = wc.x;
            hints.y = wc.y;
        }
        if((mask & CWWH) == CWWH) {
            /* PMinSize/PMaxSize (not just PSize), pinned to the same value:
             * real toolkits (confirmed against zathura, kate, pcmanfm)
             * resize themselves to fit their content between CreateNotify
             * and their own XMapWindow, landing after the XConfigureWindow
             * below and overriding it -- PSize alone is just an
             * initial-placement hint, not a constraint on the app's own
             * later requests. Pinning min==max forces the WM to clamp any
             * resize, the app's included, to this size for as long as the
             * pin holds. Apps set their own real WM_NORMAL_HINTS shortly
             * after mapping, superseding this and leaving the window freely
             * resizable again (confirmed by resizing a swallowed zathura
             * window right after launch). */
            hints.flags |= PSize | PMinSize | PMaxSize;
            hints.width = wc.width;
            hints.height = wc.height;
            hints.min_width = hints.max_width = wc.width;
            hints.min_height = hints.max_height = wc.height;
        }
        XSetWMNormalHints(dpy, win, &hints);
    }

    XConfigureWindow(dpy, win, mask, &wc);
}

/* Wait for the next top-level window to be created and mapped, up to
 * timeout_sec seconds (0 waits forever). Returns None on timeout -- the
 * launched command may exit long before its real window appears, so a bad
 * command or one that never opens a window would otherwise hang forever.
 *
 * No explicit candidate list: X only delivers a *self*-addressed MapNotify
 * (event == window) to a client that called XSelectInput directly on that
 * window; the relayed kind from root's SubstructureNotifyMask has event ==
 * root instead. Since we only ever select directly on qualifying
 * CreateNotify windows below, a self-addressed MapNotify already proves
 * it's one of ours.
 *
 * Every qualifying window stays tracked, not just the first: apps like Kate
 * can create a non-override-redirect helper window (session restore
 * prompt, IME/drag proxy) before their real one, and committing to only
 * the first would hang forever if it never itself maps or closes. */
static Window wait_for_target_window(Display *dpy, Window root, long timeout_sec,
                                      XWindowChanges wc, unsigned int mask) {
    time_t deadline = timeout_sec > 0 ? time(NULL) + timeout_sec : 0;
    int fd = ConnectionNumber(dpy);

    for (;;) {
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);

            if(ev.type == CreateNotify) {
                XCreateWindowEvent *ce = &ev.xcreatewindow;
                if(ce->parent != root || ce->override_redirect)
                    continue;

                /* Select directly on the window (not just SubstructureNotify
                 * on root) so we keep tracking it after the WM reparents it
                 * into a frame -- and so its MapNotify arrives
                 * self-addressed. */
                XSelectInput(dpy, ce->window, StructureNotifyMask);
                apply_pre_map_placement(dpy, ce->window, wc, mask);
            } else if(ev.type == MapNotify && ev.xmap.event == ev.xmap.window) {
                return ev.xmap.window;
            }
        }

        int timeout_ms = -1; /* poll()'s "block forever" */
        if(deadline) {
            time_t remaining = deadline - time(NULL);
            if(remaining <= 0)
                return None;
            /* remaining <= MAX_TIMEOUT_SEC (main() caps -t there), so this
             * can't overflow int the way an unbounded remaining * 1000
             * could. */
            timeout_ms = (int)(remaining * 1000);
        }

        /* Blocks (bounded by timeout_ms when a deadline is set) until X data
         * is available; a signal (EINTR) just loops back around and
         * re-checks the deadline. */
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        if(poll(&pfd, 1, timeout_ms) == 0)
            return None;
    }
}

/* Waits for target to close. If track_geometry is set, also keeps out_attrs
 * and out_extents updated to target's current frame geometry/insets as they
 * change (--remain), via get_window_geometry()/get_frame_extents() on every
 * ConfigureNotify -- rather than the event's own x/y/width/height, which
 * are parent-relative unless the WM sent a synthetic one, whereas
 * get_window_geometry() handles reparenting correctly either way. Tracked
 * as we go since target can't be queried once DestroyNotify fires. Insets
 * are tracked too, not queried once, since they may not be published yet
 * when target is first seen (e.g. right after the WM reparents it). */
static void wait_for_window_close(Display *dpy, Window root, Window target, Atom net_frame_extents,
                                   int track_geometry, XWindowAttributes *out_attrs,
                                   frame_extents_t out_extents) {
    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if(ev.type == DestroyNotify && ev.xdestroywindow.window == target)
            return;
        if(track_geometry && ev.type == ConfigureNotify && ev.xconfigure.window == target) {
            get_window_geometry(dpy, target, root, out_attrs);
            get_frame_extents(dpy, target, net_frame_extents, out_extents);
        }
    }
}

int main(int argc, char **argv) {
    int have_x = 0, have_y = 0, have_w = 0, have_l = 0;
    long val_x = 0, val_y = 0, val_w = 0, val_l = 0;
    long timeout_sec = DEFAULT_TIMEOUT_SEC;
    int want_default = 0, want_occupy = 0, want_fullscreen = 0, want_remain = 0, want_kill = 0;

    int c;
    /* Leading '+' stops at the first non-option argument (the command to
     * launch) instead of permuting argv -- its flags aren't ours to parse. */
    while ((c = getopt_long(argc, argv, "+x:y:w:l:t:dofrkh", long_opts, NULL)) != -1) {
        switch (c) {
        case 'x':
            if(!parse_long(optarg, &val_x)) { fprintf(stderr, "swallow: -x/--x requires a numeric argument\n"); return 1; }
            have_x = 1;
            break;
        case 'y':
            if(!parse_long(optarg, &val_y)) { fprintf(stderr, "swallow: -y/--y requires a numeric argument\n"); return 1; }
            have_y = 1;
            break;
        case 'w':
            /* X rejects a 0 width outright (BadValue), and our error handler
             * ignores that -- so unlike -x/-y, 0 isn't a valid value to let
             * through here, just one that would silently do nothing. */
            if(!parse_long(optarg, &val_w) || val_w <= 0) { fprintf(stderr, "swallow: -w/--width requires a positive numeric argument\n"); return 1; }
            have_w = 1;
            break;
        case 'l':
            if(!parse_long(optarg, &val_l) || val_l <= 0) { fprintf(stderr, "swallow: -l/--length requires a positive numeric argument\n"); return 1; }
            have_l = 1;
            break;
        case 't':
            if(!parse_long(optarg, &timeout_sec) || timeout_sec < 0) { fprintf(stderr, "swallow: -t/--timeout requires a non-negative numeric argument\n"); return 1; }
            /* Capped, not rejected: a finite wait past an hour is no more
             * useful than --timeout 0 (unlimited) for what's meant to guard
             * against a typo'd/crashing launch, and keeping it well under
             * the poll()-ms int range means wait_for_target_window's own
             * overflow clamp never actually has to trigger. 0 stays
             * uncapped -- it already means "wait forever" on purpose. */
            if(timeout_sec > MAX_TIMEOUT_SEC)
                timeout_sec = MAX_TIMEOUT_SEC;
            break;
        case 'd': want_default = 1; break;
        case 'o': want_occupy = 1; break;
        case 'f': want_fullscreen = 1; break;
        case 'r': want_remain = 1; break;
        case 'k': want_kill = 1; break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }

    if(want_default && want_occupy) {
        fprintf(stderr, "swallow: --default and --occupy are mutually exclusive\n");
        return 1;
    }
    if(want_kill && want_remain) {
        /* --remain only controls where the terminal is restored to; --kill
         * skips restoring it entirely, so combining them can only mean one
         * flag's intent was ignored. */
        fprintf(stderr, "swallow: --kill and --remain are mutually exclusive\n");
        return 1;
    }
    if(want_occupy && (have_x || have_y || have_w || have_l)) {
        /* --occupy already determines the full geometry; silently
         * overriding one axis would leave it unclear which wins. */
        fprintf(stderr, "swallow: --occupy cannot be combined with -x/-y/-w/-l\n");
        return 1;
    }
    if(optind >= argc) {
        usage(argv[0]);
        return 1;
    }
    char **cmd_argv = &argv[optind];

    Display *dpy = XOpenDisplay(NULL);
    if(!dpy) {
        fprintf(stderr, "swallow: cannot open X display\n");
        return 1;
    }
    XSetErrorHandler(x_error_handler);

    Window root = DefaultRootWindow(dpy);
    Atom net_active_window = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    Atom net_moveresize_window = XInternAtom(dpy, "_NET_MOVERESIZE_WINDOW", False);
    Atom net_frame_extents = XInternAtom(dpy, "_NET_FRAME_EXTENTS", False);
    Atom wm_protocols = XInternAtom(dpy, "WM_PROTOCOLS", False);
    Atom wm_delete_window = XInternAtom(dpy, "WM_DELETE_WINDOW", False);

    Window term_win = get_active_window(dpy, root, net_active_window);
    if(term_win == None) {
        fprintf(stderr, "swallow: could not determine the terminal window\n");
        return 1;
    }

    /* Withdrawing forgets the window's geometry with the WM, so remapping
     * later re-triggers its placement policy instead of restoring the old
     * spot -- save it here and reassert it below. Computed before target
     * exists since it's also needed for the pre-map placement passed into
     * wait_for_target_window. */
    XWindowAttributes term_attrs;
    get_window_geometry(dpy, term_win, root, &term_attrs);

    /* _NET_MOVERESIZE_WINDOW's width/height set the *client* area, not the
     * decorated footprint, so shrink by the terminal's own insets -- reused
     * below for the terminal's restore too, since that's the client size
     * that gets it back to term_attrs.width x term_attrs.height. */
    frame_extents_t extents;
    get_frame_extents(dpy, term_win, net_frame_extents, extents);
    int client_w = clamp_positive(term_attrs.width - extents[EXT_LEFT] - extents[EXT_RIGHT], term_attrs.width);
    int client_h = clamp_positive(term_attrs.height - extents[EXT_TOP] - extents[EXT_BOTTOM], term_attrs.height);

    /* Same geometry the post-map correction below sends, applied
     * speculatively pre-map (see apply_pre_map_placement) so the new window
     * never visibly appears anywhere else first. */
    XWindowChanges pl_wc = {0};
    unsigned int pl_mask = 0;
    if(want_occupy) {
        pl_wc.x = term_attrs.x;
        pl_wc.y = term_attrs.y;
        pl_wc.width = client_w;
        pl_wc.height = client_h;
        pl_mask = CWXY | CWWH;
    } else if(!want_default && (have_x || have_y || have_w || have_l)) {
        if(have_x) { pl_wc.x = (int)val_x; pl_mask |= CWX; }
        if(have_y) { pl_wc.y = (int)val_y; pl_mask |= CWY; }
        if(have_w) { pl_wc.width = (int)val_w; pl_mask |= CWWidth; }
        if(have_l) { pl_wc.height = (int)val_l; pl_mask |= CWHeight; }
    }
    /* else: --default, or no placement options at all -- leave the WM's own
     * placement alone, pre-map and post-map alike. */

    /* Select before forking so a very fast CreateNotify can't be missed. */
    XSelectInput(dpy, root, SubstructureNotifyMask);
    XFlush(dpy);

    pid_t child = fork();
    if(child < 0) {
        perror("swallow: fork");
        return 1;
    }
    if(child == 0) {
        execvp(cmd_argv[0], cmd_argv);
        fprintf(stderr, "swallow: exec %s: %s\n", cmd_argv[0], strerror(errno));
        _exit(127);
    }

    Window target = wait_for_target_window(dpy, root, timeout_sec, pl_wc, pl_mask);
    if(target == None) {
        fprintf(stderr, "swallow: timed out after %lds waiting for a window from %s\n",
                timeout_sec, cmd_argv[0]);
        XCloseDisplay(dpy);
        return 1;
    }

    /* Fullscreen is an EWMH *state*, not a geometry override: the WM tracks
     * the window's "normal" geometry underneath it and restores that if
     * fullscreen is toggled off. So normal-state geometry is set here
     * regardless of --full-screen, which layers on top rather than
     * replacing it.
     *
     * Resends the geometry apply_pre_map_placement already applied before
     * target was mapped -- a fallback for WMs that ignore a pre-map
     * XConfigureWindow/hint, same belt-and-braces pattern as the terminal
     * restore.
     *
     * pl_mask/pl_wc (built pre-fork) already hold what to apply, for
     * --occupy and manual placement alike; pl_mask is 0 for --default/no
     * flags, so this is skipped then too. _NET_MOVERESIZE_WINDOW's
     * presence-flag bits (x/y/width/height, bits 8-11) happen to sit at the
     * same relative positions as CWX/CWY/CWWidth/CWHeight (bits 0-3), so
     * pl_mask << 8 produces them directly -- a coincidence between two
     * unrelated bit layouts, not something to rely on elsewhere. Unset
     * fields are ignored by the recipient regardless of value. */
    if(pl_mask) {
        send_client_message(dpy, target, root, net_moveresize_window,
                             (2 << 12) | (pl_mask << 8),
                             pl_wc.x, pl_wc.y, pl_wc.width, pl_wc.height);
    }

    if(want_fullscreen) {
        Atom net_wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
        Atom net_wm_state_fullscreen = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
        /* _NET_WM_STATE: action=1 (add), property=_NET_WM_STATE_FULLSCREEN,
         * source indication=2 (pager/tool). */
        send_client_message(dpy, target, root, net_wm_state,
                             1, (long)net_wm_state_fullscreen, 0, 2, 0);
    }

    /* --remain: track target's geometry/insets as it moves/resizes, so the
     * terminal can take its place once it closes. Reuses term_attrs (its
     * original value is only needed past this point as the !want_remain
     * fallback, which is exactly what's left in it when tracking is off).
     * Overwritten here rather than left stale in case target closes before
     * its first ConfigureNotify arrives. */
    frame_extents_t remain_extents;
    memcpy(remain_extents, extents, sizeof(extents));
    if(want_remain) {
        get_window_geometry(dpy, target, root, &term_attrs);
        get_frame_extents(dpy, target, net_frame_extents, remain_extents);
    }

    /* Unmapping (not iconifying) makes the terminal actually disappear:
     * ICCCM Normal -> Withdrawn drops it from the taskbar/pager instead of
     * leaving a minimized entry. */
    XUnmapWindow(dpy, term_win);
    XFlush(dpy);

    wait_for_window_close(dpy, root, target, net_frame_extents, want_remain,
                           &term_attrs, remain_extents);

    /* --kill: skip the restore and close the terminal instead -- see
     * close_window() for why this isn't just another send_client_message()
     * call. */
    if(want_kill) {
        close_window(dpy, term_win, wm_protocols, wm_delete_window);
        XFlush(dpy);
        int status;
        waitpid(child, &status, WNOHANG);
        XCloseDisplay(dpy);
        return 0;
    }

    /* Restore geometry: target's last-known spot for --remain, otherwise the
     * terminal's own original spot -- term_attrs already holds whichever
     * applies. For --remain, term_attrs.width/height is target's last FRAME
     * size, converted to a client size using target's OWN insets
     * (remain_extents -- a copy of the terminal's insets when !want_remain,
     * so this reduces to client_w/client_h in that case). Using the
     * terminal's own insets instead would only cancel out if the two
     * windows share identical decorations; when they don't (per-app
     * theming, undecorated windows), since --occupy sized target off the
     * terminal's *previous* geometry, the wrong insets would feed a
     * slightly wrong size back as the terminal's next "previous geometry",
     * compounding a little further on every --occupy + --remain cycle.
     * Target's own insets make the round trip exact: the terminal's frame
     * still ends up at term_attrs.width/height, but its client size matches
     * target's actual client size, so repeated cycles stay stable instead
     * of drifting. */
    int restore_x = term_attrs.x, restore_y = term_attrs.y;
    int restore_w = clamp_positive(term_attrs.width - remain_extents[EXT_LEFT] - remain_extents[EXT_RIGHT], term_attrs.width);
    int restore_h = clamp_positive(term_attrs.height - remain_extents[EXT_TOP] - remain_extents[EXT_BOTTOM], term_attrs.height);

    /* Withdrawing forgets the window's spot as far as *placement policy*
     * (cascade/center/etc.) goes, but Openbox still separately remembers
     * its last on-screen geometry and puts it straight back there on remap
     * -- confirmed via an event-trace repro: remapping after only a
     * PPosition hint plus a post-map _NET_MOVERESIZE_WINDOW correction
     * visibly jumped to the pre-unmap spot first, then to the restore spot
     * a few ms later. _NET_MOVERESIZE_WINDOW is for repositioning an
     * *already-mapped* window (e.g. a pager); Openbox ignores it while
     * withdrawn, sent pre-map or not. A plain XMoveResizeWindow works: it's
     * how a client sets its own pre-map geometry, so Openbox picks it up as
     * the window's current geometry and remaps it there directly, no
     * intermediate jump. XSync confirms it's applied before mapping. */
    XMoveResizeWindow(dpy, term_win, restore_x, restore_y, restore_w, restore_h);
    XSync(dpy, False);

    /* Belt-and-braces alongside the moveresize above: a PPosition hint gets
     * ICCCM-compliant WMs that *do* run placement policy on remap (unlike
     * Openbox's "remember its own spot" above) to honor this position too.
     * Deliberately position-only, not PSize/width/height: a remap is
     * treated like a fresh initial map, so a size hint gets rounded to the
     * window's own PResizeInc/PBaseSize (e.g. xterm's character-cell size),
     * shrinking it a little on every restore -- size is left to the
     * already-correct _NET_MOVERESIZE_WINDOW call below. Read-modify-write
     * since term_win may carry other hints (e.g. that same resize
     * increment) that must survive. */
    XSizeHints hints;
    long supplied;
    if(!XGetWMNormalHints(dpy, term_win, &hints, &supplied))
        hints.flags = 0;
    hints.flags |= PPosition;
    hints.x = restore_x;
    hints.y = restore_y;
    XSetWMNormalHints(dpy, term_win, &hints);

    /* ICCCM: Withdrawn -> Normal is done simply by mapping the window again. */
    XMapWindow(dpy, term_win);
    /* Fallback/correction if a WM ignored the pre-map request above
     * (gravity 0 uses the window's own, source indication 2 (pager/tool),
     * x/y/width/height all present via bits 8-11). */
    send_client_message(dpy, term_win, root, net_moveresize_window,
                         (2 << 12) | ((CWXY | CWWH) << 8),
                         restore_x, restore_y, restore_w, restore_h);
    send_client_message(dpy, term_win, root, net_active_window, 2, 0, 0, 0, 0);
    XFlush(dpy);

    int status;
    waitpid(child, &status, WNOHANG); /* best-effort reap; may be long gone */
    XCloseDisplay(dpy);
    return 0;
}
