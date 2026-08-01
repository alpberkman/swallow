/*
 * swallow -- run a GUI app from a terminal, hide the terminal while the
 * app's window is open, and bring the terminal back when it closes.
 *
 * Usage: swallow <command> [args...]
 *
 * The terminal is whatever window is active (_NET_ACTIVE_WINDOW) when
 * swallow starts. The launched command's window is simply the next new
 * top-level window to be created and mapped after that. This deliberately
 * doesn't try to match it to the launched process's PID: plenty of apps
 * hand the real work off to something with no process relationship to what
 * was just exec'd at all -- fork+exec launchers, double-fork daemonizing,
 * or (e.g. Kate, via kdeinit/D-Bus single-instance activation) an
 * unrelated, already-running process entirely. Any PID-based heuristic
 * breaks on one of these sooner or later; just watching for the next
 * window handles all of them uniformly.
 *
 * The new window's placement is set per the --x/--y/--width/--length/
 * --default/--occupy/--full-screen flags (see --help): speculatively before
 * it's even mapped (as soon as it's a CreateNotify candidate -- see
 * apply_pre_map_placement), and again as a fallback once it's confirmed as
 * the real target, so it never visibly appears anywhere but the requested
 * spot. The default (no flags) is to leave placement to the WM. If no
 * window shows up within --timeout seconds (default 3), swallow gives up
 * and exits without ever hiding the terminal.
 *
 * The terminal is hidden by unmapping it (ICCCM Normal -> Withdrawn), which
 * drops it from the taskbar/pager entirely -- not just iconify, which would
 * leave a minimized entry behind. It's restored by mapping it again
 * (Withdrawn -> Normal), re-asserting its geometry (withdrawing forgets it,
 * so the WM's placement policy would otherwise relocate/resize it), and
 * focusing it via _NET_ACTIVE_WINDOW. Normally that reasserted geometry is
 * the terminal's own original spot; with --remain it's instead wherever the
 * app's window last was before it closed.
 */

#define _DEFAULT_SOURCE
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
    {"help", no_argument, NULL, 'h'},
    {NULL, 0, NULL, 0},
};

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [options] <command> [args...]\n"
        "\n"
        "Options (all affect only where/how the new window is placed):\n"
        "  -x, --x <n>        X position for the new window\n"
        "  -y, --y <n>        Y position for the new window\n"
        "  -w, --width <n>    Width for the new window\n"
        "  -l, --length <n>   Height for the new window\n"
        "  -d, --default      Let the window manager choose size/position (the default)\n"
        "  -o, --occupy       Make the new window occupy the terminal's exact spot\n"
        "  -f, --full-screen  Start the new window full-screen\n"
        "  -t, --timeout <n>  Give up if no window appears within n seconds\n"
        "                     (default %d; 0 waits forever)\n"
        "  -r, --remain       When the app's window closes, put the terminal where\n"
        "                     that window ended up instead of restoring the\n"
        "                     terminal's original position/size\n"
        "  -h, --help         Show this help and exit\n"
        "\n"
        "--default and --occupy are mutually exclusive. With no options at all,\n"
        "--default is used. --x/--y/--width/--length may be used individually or\n"
        "together to place the window manually; any not given are left to the app/WM.\n"
        "They cannot be combined with --occupy, which already determines the full\n"
        "geometry itself. --full-screen composes with the others rather than\n"
        "replacing them: it's the geometry the window returns to if full-screen is\n"
        "ever turned off.\n",
        prog, DEFAULT_TIMEOUT_SEC);
}

/* strtol(), but rejecting anything that isn't *entirely* a valid number --
 * including the empty string, which strtol treats as "0 consumed" and, for
 * an empty argument specifically, leaves *endptr == '\0' too (since endptr
 * is set to the input pointer itself, which for "" already points at the
 * terminator) -- so a bare `*end != '\0'` check alone lets an empty string
 * silently through as 0. */
static int parse_long(const char *s, long *out) {
    char *end;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0')
        return 0;
    *out = v;
    return 1;
}

static int x_error_handler(Display *dpy, XErrorEvent *e) {
    (void)dpy;
    (void)e;
    return 0; /* don't let a stray error (e.g. a since-destroyed window) kill us */
}

static Window get_active_window(Display *dpy, Window root, Atom net_active_window) {
    Atom type;
    int format;
    unsigned long nitems, after;
    unsigned char *prop = NULL;
    Window result = None;

    if (XGetWindowProperty(dpy, root, net_active_window, 0, 1, False, XA_WINDOW,
                            &type, &format, &nitems, &after, &prop) == Success) {
        if (prop && nitems >= 1)
            result = *(Window *)prop;
        if (prop)
            XFree(prop);
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

/* Root-relative screen geometry of win, using its decoration frame (the WM
 * reparents managed windows one level under root) if it has one. */
static void get_window_geometry(Display *dpy, Window win, Window root,
                                 int *x, int *y, int *w, int *h) {
    Window r, parent, *children = NULL;
    unsigned int nchildren = 0;
    Window target = win;

    if (XQueryTree(dpy, win, &r, &parent, &children, &nchildren)) {
        if (children)
            XFree(children);
        if (parent != None && parent != root)
            target = parent;
    }

    XWindowAttributes attrs;
    if (XGetWindowAttributes(dpy, target, &attrs)) {
        *x = attrs.x;
        *y = attrs.y;
        *w = attrs.width;
        *h = attrs.height;
    } else {
        *x = *y = *w = *h = 0;
    }
}

/* win's decoration insets (_NET_FRAME_EXTENTS: left, right, top, bottom),
 * i.e. how much smaller its usable client area is than its full on-screen
 * footprint. All zero if the WM hasn't published it (e.g. undecorated). */
static void get_frame_extents(Display *dpy, Window win, Atom net_frame_extents,
                               int *left, int *right, int *top, int *bottom) {
    Atom type;
    int format;
    unsigned long nitems, after;
    unsigned char *prop = NULL;
    *left = *right = *top = *bottom = 0;

    if (XGetWindowProperty(dpy, win, net_frame_extents, 0, 4, False, XA_CARDINAL,
                            &type, &format, &nitems, &after, &prop) == Success) {
        if (prop && nitems == 4) {
            long *vals = (long *)prop;
            *left = (int)vals[0];
            *right = (int)vals[1];
            *top = (int)vals[2];
            *bottom = (int)vals[3];
        }
        if (prop)
            XFree(prop);
    }
}

/* Geometry to speculatively apply to every create-notified candidate window
 * before the launched app itself ever gets to map it -- see
 * apply_pre_map_placement(). set_x/set_y/set_w/set_h mirror -x/-y/-w/-l
 * being usable individually; all zero means no pre-map placement at all
 * (--default, or no placement options given). */
typedef struct {
    int set_x, set_y, set_w, set_h;
    int x, y, w, h;
} placement_t;

/* Applied to every qualifying candidate window as soon as it's created --
 * not just the confirmed target, since which candidate is real isn't known
 * until MapNotify (see wait_for_target_window) and applying this to a
 * phantom/decoy window that never gets mapped is harmless.
 *
 * This is the pre-map analogue of the XMoveResizeWindow trick used for the
 * terminal's own restore, and for the same reason: an event-trace repro (a
 * helper mirroring this function's own CreateNotify/ConfigureNotify logic)
 * showed the target window actually gets mapped at the WM's own default
 * placement (e.g. xmessage's requested center-of-screen spot) and only
 * jumps to the requested --occupy/manual spot a few ConfigureNotify events
 * later, once wait_for_target_window returns and the post-map
 * _NET_MOVERESIZE_WINDOW correction below is sent -- a visible flash into
 * the wrong spot first, exactly like the terminal restore case. Setting the
 * geometry directly before the window is ever mapped, the same mechanism a
 * client uses for its own first-map geometry, gets the WM to place it there
 * immediately instead.
 *
 * XConfigureWindow (not XMoveResizeWindow) is used since it alone can set a
 * subset of x/y/width/height, needed for manual placement where only some
 * axes are given. WM_NORMAL_HINTS is set alongside as belt-and-braces for
 * WMs that honor the hint on an unmapped window but not a bare geometry
 * change -- but only when a full pair (both x and y, or both w and h) is
 * given, since PPosition/PSize apply to both axes of a pair at once and
 * setting one without the other would misrepresent the unset axis as
 * "0" or "1" rather than "unspecified". */
static void apply_pre_map_placement(Display *dpy, Window win, const placement_t *pl) {
    if (!pl->set_x && !pl->set_y && !pl->set_w && !pl->set_h)
        return;

    XWindowChanges wc;
    unsigned int mask = 0;
    if (pl->set_x) { wc.x = pl->x; mask |= CWX; }
    if (pl->set_y) { wc.y = pl->y; mask |= CWY; }
    if (pl->set_w) { wc.width = pl->w; mask |= CWWidth; }
    if (pl->set_h) { wc.height = pl->h; mask |= CWHeight; }
    XConfigureWindow(dpy, win, mask, &wc);

    if ((pl->set_x && pl->set_y) || (pl->set_w && pl->set_h)) {
        XSizeHints hints;
        long supplied;
        if (!XGetWMNormalHints(dpy, win, &hints, &supplied))
            hints.flags = 0;
        if (pl->set_x && pl->set_y) {
            hints.flags |= PPosition;
            hints.x = pl->x;
            hints.y = pl->y;
        }
        if (pl->set_w && pl->set_h) {
            hints.flags |= PSize;
            hints.width = pl->w;
            hints.height = pl->h;
        }
        XSetWMNormalHints(dpy, win, &hints);
    }
}

/* Wait for the next top-level window to be created and mapped, up to
 * timeout_sec seconds (0 waits forever). Returns None on timeout: whatever
 * swallow launched may exit long before the real window shows up (see file
 * header comment), so there's otherwise no exit condition to race against
 * other than a window actually appearing -- a bad command or a launch that
 * never opens a window would hang forever without this.
 *
 * Doesn't keep an explicit candidate list. Instead it relies on how X
 * delivers MapNotify: a client only gets a *self*-addressed one (event ==
 * window) for a window it called XSelectInput(..., StructureNotifyMask) on
 * directly; the relayed kind from root's SubstructureNotifyMask instead has
 * event == root. Since the only windows we ever select directly on are
 * qualifying CreateNotify windows below, seeing a self-addressed MapNotify
 * already proves it's one of ours -- no separate bookkeeping needed.
 *
 * This also means every qualifying window stays tracked, not just the
 * first: apps like Kate (KDE/Qt, via kdeinit/D-Bus activation) can create a
 * non-override-redirect helper window (session restore prompt, IME/drag
 * proxy, etc.) before their real main window, and committing to only the
 * first one seen would get stuck waiting on it forever if it never itself
 * maps or closes, even after the real window has already appeared. */
static Window wait_for_target_window(Display *dpy, Window root, long timeout_sec,
                                      const placement_t *pl) {
    time_t deadline = timeout_sec > 0 ? time(NULL) + timeout_sec : 0;
    int fd = ConnectionNumber(dpy);

    for (;;) {
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);

            if (ev.type == CreateNotify) {
                XCreateWindowEvent *ce = &ev.xcreatewindow;
                if (ce->parent != root || ce->override_redirect)
                    continue;

                /* Select directly on the window (not just SubstructureNotify
                 * on root) so we keep tracking it after the WM reparents it
                 * into a frame -- and so its MapNotify arrives
                 * self-addressed. */
                XSelectInput(dpy, ce->window, StructureNotifyMask);
                apply_pre_map_placement(dpy, ce->window, pl);
            } else if (ev.type == MapNotify && ev.xmap.event == ev.xmap.window) {
                return ev.xmap.window;
            }
        }

        int timeout_ms = -1; /* poll()'s "block forever" */
        if (deadline) {
            time_t remaining = deadline - time(NULL);
            if (remaining <= 0)
                return None;
            timeout_ms = (int)(remaining * 1000);
        }

        /* Blocks (bounded by timeout_ms when a deadline is set) until X data
         * is available; a signal (EINTR) just loops back around and
         * re-checks the deadline. */
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int r = poll(&pfd, 1, timeout_ms);
        if (r == 0)
            return None;
    }
}

/* Waits for target to close. If track_geometry is set, also keeps the
 * out_x, out_y, out_w, out_h, out_left/right/top/bottom outputs updated to
 * target's current on-screen frame geometry and decoration insets as they
 * change (--remain), by re-deriving them via get_window_geometry()/
 * get_frame_extents() on every ConfigureNotify target gets -- rather than
 * trusting the event's own x/y/width/height, since those are parent-relative
 * unless the WM happened to send a synthetic (root-relative) one, and
 * get_window_geometry() already does the reparenting-aware lookup correctly
 * regardless of which kind arrived. By the time DestroyNotify fires the
 * window is gone and can't be queried anymore, hence tracking as we go
 * rather than at close time. Insets are tracked alongside geometry (not
 * just queried once) because they may not be published yet at the moment
 * target is first seen -- e.g. right after the WM has just reparented it. */
static void wait_for_window_close(Display *dpy, Window root, Window target, Atom net_frame_extents,
                                   int track_geometry, int *out_x, int *out_y, int *out_w, int *out_h,
                                   int *out_left, int *out_right, int *out_top, int *out_bottom) {
    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == DestroyNotify && ev.xdestroywindow.window == target)
            return;
        if (track_geometry && ev.type == ConfigureNotify && ev.xconfigure.window == target) {
            get_window_geometry(dpy, target, root, out_x, out_y, out_w, out_h);
            get_frame_extents(dpy, target, net_frame_extents, out_left, out_right, out_top, out_bottom);
        }
    }
}

int main(int argc, char **argv) {
    int have_x = 0, have_y = 0, have_w = 0, have_l = 0;
    long val_x = 0, val_y = 0, val_w = 0, val_l = 0;
    long timeout_sec = DEFAULT_TIMEOUT_SEC;
    int want_default = 0, want_occupy = 0, want_fullscreen = 0, want_remain = 0;

    int c;
    /* Leading '+' stops at the first non-option argument (the command to
     * launch) instead of permuting the whole argv -- its own flags aren't
     * ours to parse. */
    while ((c = getopt_long(argc, argv, "+x:y:w:l:t:dofrh", long_opts, NULL)) != -1) {
        switch (c) {
        case 'x':
            if (!parse_long(optarg, &val_x)) { fprintf(stderr, "swallow: -x/--x requires a numeric argument\n"); return 1; }
            have_x = 1;
            break;
        case 'y':
            if (!parse_long(optarg, &val_y)) { fprintf(stderr, "swallow: -y/--y requires a numeric argument\n"); return 1; }
            have_y = 1;
            break;
        case 'w':
            if (!parse_long(optarg, &val_w) || val_w < 0) { fprintf(stderr, "swallow: -w/--width requires a non-negative numeric argument\n"); return 1; }
            have_w = 1;
            break;
        case 'l':
            if (!parse_long(optarg, &val_l) || val_l < 0) { fprintf(stderr, "swallow: -l/--length requires a non-negative numeric argument\n"); return 1; }
            have_l = 1;
            break;
        case 't':
            if (!parse_long(optarg, &timeout_sec) || timeout_sec < 0) { fprintf(stderr, "swallow: -t/--timeout requires a non-negative numeric argument\n"); return 1; }
            break;
        case 'd': want_default = 1; break;
        case 'o': want_occupy = 1; break;
        case 'f': want_fullscreen = 1; break;
        case 'r': want_remain = 1; break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }

    if (want_default && want_occupy) {
        fprintf(stderr, "swallow: --default and --occupy are mutually exclusive\n");
        return 1;
    }
    if (want_occupy && (have_x || have_y || have_w || have_l)) {
        /* --occupy already determines the new window's full geometry from
         * the terminal's; silently overriding just one axis would leave it
         * unclear which one wins, so reject instead of guessing. */
        fprintf(stderr, "swallow: --occupy cannot be combined with -x/-y/-w/-l\n");
        return 1;
    }
    if (optind >= argc) {
        usage(argv[0]);
        return 1;
    }
    char **cmd_argv = &argv[optind];

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "swallow: cannot open X display\n");
        return 1;
    }
    XSetErrorHandler(x_error_handler);

    Window root = DefaultRootWindow(dpy);
    Atom net_active_window = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    Atom net_moveresize_window = XInternAtom(dpy, "_NET_MOVERESIZE_WINDOW", False);
    Atom net_frame_extents = XInternAtom(dpy, "_NET_FRAME_EXTENTS", False);

    Window term_win = get_active_window(dpy, root, net_active_window);
    if (term_win == None) {
        fprintf(stderr, "swallow: could not determine the terminal window\n");
        return 1;
    }

    /* Withdrawing forgets the window's geometry with the WM, so remapping
     * later re-triggers its placement policy (e.g. re-centering) instead of
     * putting it back where it was -- save it here and re-assert it below.
     * Computed now (before the target even exists) rather than after
     * wait_for_target_window returns, since it's also needed below to build
     * the pre-map placement passed into that call. */
    int term_x, term_y, term_w, term_h;
    get_window_geometry(dpy, term_win, root, &term_x, &term_y, &term_w, &term_h);

    /* _NET_MOVERESIZE_WINDOW's width/height set the *client* area, not the
     * decorated footprint, so shrink by the terminal's own decoration
     * insets -- reused below for the terminal's own restore too, since
     * that's exactly the client size that gets it back to term_w x term_h. */
    int left, right, top, bottom;
    get_frame_extents(dpy, term_win, net_frame_extents, &left, &right, &top, &bottom);
    int client_w = term_w - left - right;
    int client_h = term_h - top - bottom;
    if (client_w <= 0)
        client_w = term_w;
    if (client_h <= 0)
        client_h = term_h;

    /* Same geometry the post-map correction below would send, but applied
     * speculatively pre-map (see apply_pre_map_placement) so the new window
     * never visibly appears anywhere else first. */
    placement_t pl = {0};
    if (want_occupy) {
        pl.set_x = pl.set_y = pl.set_w = pl.set_h = 1;
        pl.x = term_x; pl.y = term_y; pl.w = client_w; pl.h = client_h;
    } else if (!want_default && (have_x || have_y || have_w || have_l)) {
        pl.set_x = have_x; pl.x = (int)val_x;
        pl.set_y = have_y; pl.y = (int)val_y;
        pl.set_w = have_w; pl.w = (int)val_w;
        pl.set_h = have_l; pl.h = (int)val_l;
    }
    /* else: --default, or no placement options at all -- leave the WM's own
     * placement alone, pre-map and post-map alike. */

    /* Select before forking so a very fast CreateNotify can't be missed. */
    XSelectInput(dpy, root, SubstructureNotifyMask);
    XFlush(dpy);

    pid_t child = fork();
    if (child < 0) {
        perror("swallow: fork");
        return 1;
    }
    if (child == 0) {
        execvp(cmd_argv[0], cmd_argv);
        fprintf(stderr, "swallow: exec %s: %s\n", cmd_argv[0], strerror(errno));
        _exit(127);
    }

    Window target = wait_for_target_window(dpy, root, timeout_sec, &pl);
    if (target == None) {
        fprintf(stderr, "swallow: timed out after %lds waiting for a window from %s\n",
                timeout_sec, cmd_argv[0]);
        XCloseDisplay(dpy);
        return 1;
    }

    /* Fullscreen is an EWMH *state*, not a geometry override: the WM keeps
     * track of the window's "normal" geometry underneath it and restores
     * that if fullscreen is ever toggled off. So the normal-state geometry
     * below is still set according to --occupy/manual/--default regardless
     * of --full-screen; fullscreen is layered on top of it, not instead.
     *
     * This re-sends the same geometry apply_pre_map_placement already
     * applied before target was ever mapped (see wait_for_target_window) --
     * kept as a fallback/correction for WMs that ignore a pre-map
     * XConfigureWindow/hint, exactly like the terminal restore's own
     * belt-and-braces pre-map-call-plus-post-map-correction pattern. */
    if (want_occupy) {
        /* Make the new window occupy the exact spot the terminal was in. */
        send_client_message(dpy, target, root, net_moveresize_window,
                             (2 << 12) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11),
                             term_x, term_y, client_w, client_h);
    } else if (!want_default && (have_x || have_y || have_w || have_l)) {
        /* Manual placement: only the axes actually given are forced, so
         * e.g. --x alone leaves y/width/height to the app/WM. */
        long flags = (2 << 12);
        if (have_x) flags |= (1 << 8);
        if (have_y) flags |= (1 << 9);
        if (have_w) flags |= (1 << 10);
        if (have_l) flags |= (1 << 11);
        send_client_message(dpy, target, root, net_moveresize_window,
                             flags, val_x, val_y, val_w, val_l);
    }
    /* else: --default, or no placement options at all -- leave the WM's
     * own placement alone. */

    if (want_fullscreen) {
        Atom net_wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
        Atom net_wm_state_fullscreen = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
        /* _NET_WM_STATE: action=1 (add), property=_NET_WM_STATE_FULLSCREEN,
         * source indication=2 (pager/tool). */
        send_client_message(dpy, target, root, net_wm_state,
                             1, (long)net_wm_state_fullscreen, 0, 2, 0);
    }

    /* --remain: track target's geometry (and its own decoration insets --
     * see below) as it moves/resizes, so that once it closes the terminal
     * can take its place instead of its own old spot. Seeded here (rather
     * than left zeroed) in case target closes before its first
     * ConfigureNotify ever arrives. */
    int remain_x = term_x, remain_y = term_y, remain_w = term_w, remain_h = term_h;
    int remain_left = left, remain_right = right, remain_top = top, remain_bottom = bottom;
    if (want_remain) {
        get_window_geometry(dpy, target, root, &remain_x, &remain_y, &remain_w, &remain_h);
        get_frame_extents(dpy, target, net_frame_extents, &remain_left, &remain_right, &remain_top, &remain_bottom);
    }

    /* Unmapping (rather than iconifying) makes the terminal actually
     * disappear: ICCCM's Normal -> Withdrawn transition, which drops it
     * from the taskbar/pager entirely instead of leaving a minimized entry. */
    XUnmapWindow(dpy, term_win);
    XFlush(dpy);

    wait_for_window_close(dpy, root, target, net_frame_extents, want_remain,
                           &remain_x, &remain_y, &remain_w, &remain_h,
                           &remain_left, &remain_right, &remain_top, &remain_bottom);

    /* Restore geometry: target's last-known spot for --remain, otherwise the
     * terminal's own original spot. For --remain, remain_w/h is target's
     * last FRAME size, so it has to be converted to a client size using
     * target's OWN insets (remain_left/right/top/bottom), not the
     * terminal's -- using the terminal's insets here would only cancel out
     * if the two windows happen to share identical decorations. When they
     * don't (common: per-app theming, undecorated windows, etc.), that
     * mismatch doesn't just misplace this one restore -- since --occupy's
     * own placement of target was itself sized off of the terminal's
     * previous geometry, using the wrong insets here feeds a slightly
     * wrong size back as the terminal's new "previous geometry" for the
     * *next* swallow invocation, compounding a little further every single
     * cycle. Using target's own insets makes the round trip exact instead:
     * the terminal's resulting frame ends up equal to remain_w/h either
     * way, but its *client* size now matches target's actual client size,
     * so repeated --occupy + --remain cycles stay stable indefinitely
     * instead of drifting. */
    int restore_x = term_x, restore_y = term_y, restore_w = client_w, restore_h = client_h;
    if (want_remain) {
        restore_x = remain_x;
        restore_y = remain_y;
        restore_w = remain_w - remain_left - remain_right;
        restore_h = remain_h - remain_top - remain_bottom;
        if (restore_w <= 0)
            restore_w = remain_w;
        if (restore_h <= 0)
            restore_h = remain_h;
    }

    /* Withdrawing forgets the window's old spot as far as *placement policy*
     * (cascade/center/under-mouse/etc.) is concerned, but Openbox (at
     * least) still separately remembers the window's own last on-screen
     * geometry and just puts it straight back there on remap, placement
     * policy or no -- confirmed with an event-trace repro (a helper
     * selecting StructureNotify on the terminal and logging every
     * ConfigureNotify with a timestamp): remapping after only a PPosition
     * hint and a post-map _NET_MOVERESIZE_WINDOW correction visibly jumped
     * to the pre-unmap spot first, then to the restore spot a few ms later.
     * _NET_MOVERESIZE_WINDOW is an EWMH request for repositioning an
     * *already-mapped* window (e.g. a pager dragging one around) and
     * Openbox appears to just ignore it while withdrawn -- sending it here,
     * before mapping, made no difference. A plain XMoveResizeWindow does,
     * though: it's how a client sets its own pre-map geometry in the first
     * place (same mechanism new windows use before their first-ever map),
     * so Openbox picks it up as the window's current geometry instead of
     * whatever it had before, and remaps it there directly with no
     * intermediate jump. XSync so this is confirmed applied before mapping. */
    XMoveResizeWindow(dpy, term_win, restore_x, restore_y, restore_w, restore_h);
    XSync(dpy, False);

    /* Belt-and-braces alongside the moveresize above: a PPosition hint gets
     * ICCCM-compliant WMs that *do* run placement policy on remap (unlike
     * Openbox's "remember its own spot" behavior above) to honor this
     * position immediately too. Position only, deliberately not PSize/
     * width/height: a remap is treated like a fresh initial map, so a size
     * hint here gets run back through the window's own PResizeInc/PBaseSize
     * (e.g. xterm's character-cell size) and rounded down to the nearest
     * valid increment -- shrinking the terminal a little on every single
     * restore. Size is left to the (already-correct) _NET_MOVERESIZE_WINDOW
     * call below, which doesn't have that problem. Read-modify-write rather
     * than a fresh XSizeHints, since term_win may already carry other hints
     * (e.g. that same resize-increment/min-size) that must survive. */
    XSizeHints hints;
    long supplied;
    if (!XGetWMNormalHints(dpy, term_win, &hints, &supplied))
        hints.flags = 0;
    hints.flags |= PPosition;
    hints.x = restore_x;
    hints.y = restore_y;
    XSetWMNormalHints(dpy, term_win, &hints);

    /* ICCCM: Withdrawn -> Normal is done simply by mapping the window again. */
    XMapWindow(dpy, term_win);
    /* Fallback/correction in case a WM ignored the pre-map request above
     * (still needed for full correctness -- gravity 0 uses the window's
     * own, source indication 2 (pager/tool), x/y/width/height all present
     * (bits 8-11)). */
    send_client_message(dpy, term_win, root, net_moveresize_window,
                         (2 << 12) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11),
                         restore_x, restore_y, restore_w, restore_h);
    send_client_message(dpy, term_win, root, net_active_window, 2, 0, 0, 0, 0);
    XFlush(dpy);

    int status;
    waitpid(child, &status, WNOHANG); /* best-effort reap; may be long gone */
    XCloseDisplay(dpy);
    return 0;
}
