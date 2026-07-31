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
 * Before hiding, the new window's placement is set per the --x/--y/--width/
 * --length/--default/--occupy/--full-screen flags (see --help). The default
 * (no flags) is to leave placement to the WM. If no window shows up within
 * --timeout seconds (default 3), swallow gives up and exits without ever
 * hiding the terminal.
 *
 * The terminal is hidden by unmapping it (ICCCM Normal -> Withdrawn), which
 * drops it from the taskbar/pager entirely -- not just iconify, which would
 * leave a minimized entry behind. It's restored by mapping it again
 * (Withdrawn -> Normal), re-asserting its old geometry (withdrawing forgets
 * it, so the WM's placement policy would otherwise relocate/resize it), and
 * focusing it via _NET_ACTIVE_WINDOW.
 */

#define _DEFAULT_SOURCE
#include <X11/Xlib.h>
#include <X11/Xatom.h>

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
        "  -h, --help         Show this help and exit\n"
        "\n"
        "--default and --occupy are mutually exclusive. With no options at all,\n"
        "--default is used. --x/--y/--width/--length may be used individually or\n"
        "together to place the window manually; any not given are left to the app/WM.\n"
        "--full-screen composes with the others rather than replacing them: it's the\n"
        "geometry the window returns to if full-screen is ever turned off.\n",
        prog, DEFAULT_TIMEOUT_SEC);
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
static Window wait_for_target_window(Display *dpy, Window root, long timeout_sec) {
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

static void wait_for_window_close(Display *dpy, Window target) {
    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == DestroyNotify && ev.xdestroywindow.window == target)
            return;
    }
}

int main(int argc, char **argv) {
    int have_x = 0, have_y = 0, have_w = 0, have_l = 0;
    long val_x = 0, val_y = 0, val_w = 0, val_l = 0;
    long timeout_sec = DEFAULT_TIMEOUT_SEC;
    int want_default = 0, want_occupy = 0, want_fullscreen = 0;

    int c;
    char *end;
    /* Leading '+' stops at the first non-option argument (the command to
     * launch) instead of permuting the whole argv -- its own flags aren't
     * ours to parse. */
    while ((c = getopt_long(argc, argv, "+x:y:w:l:t:dofh", long_opts, NULL)) != -1) {
        switch (c) {
        case 'x':
            val_x = strtol(optarg, &end, 10);
            if (*end != '\0') { fprintf(stderr, "swallow: -x/--x requires a numeric argument\n"); return 1; }
            have_x = 1;
            break;
        case 'y':
            val_y = strtol(optarg, &end, 10);
            if (*end != '\0') { fprintf(stderr, "swallow: -y/--y requires a numeric argument\n"); return 1; }
            have_y = 1;
            break;
        case 'w':
            val_w = strtol(optarg, &end, 10);
            if (*end != '\0') { fprintf(stderr, "swallow: -w/--width requires a numeric argument\n"); return 1; }
            have_w = 1;
            break;
        case 'l':
            val_l = strtol(optarg, &end, 10);
            if (*end != '\0') { fprintf(stderr, "swallow: -l/--length requires a numeric argument\n"); return 1; }
            have_l = 1;
            break;
        case 't':
            timeout_sec = strtol(optarg, &end, 10);
            if (*end != '\0' || timeout_sec < 0) { fprintf(stderr, "swallow: -t/--timeout requires a non-negative numeric argument\n"); return 1; }
            break;
        case 'd': want_default = 1; break;
        case 'o': want_occupy = 1; break;
        case 'f': want_fullscreen = 1; break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }

    if (want_default && want_occupy) {
        fprintf(stderr, "swallow: --default and --occupy are mutually exclusive\n");
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

    Window target = wait_for_target_window(dpy, root, timeout_sec);
    if (target == None) {
        fprintf(stderr, "swallow: timed out after %lds waiting for a window from %s\n",
                timeout_sec, cmd_argv[0]);
        XCloseDisplay(dpy);
        return 1;
    }

    /* Withdrawing forgets the window's geometry with the WM, so remapping
     * later re-triggers its placement policy (e.g. re-centering) instead of
     * putting it back where it was -- save it here and re-assert it below. */
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

    /* Fullscreen is an EWMH *state*, not a geometry override: the WM keeps
     * track of the window's "normal" geometry underneath it and restores
     * that if fullscreen is ever toggled off. So the normal-state geometry
     * below is still set according to --occupy/manual/--default regardless
     * of --full-screen; fullscreen is layered on top of it, not instead. */
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

    /* Unmapping (rather than iconifying) makes the terminal actually
     * disappear: ICCCM's Normal -> Withdrawn transition, which drops it
     * from the taskbar/pager entirely instead of leaving a minimized entry. */
    XUnmapWindow(dpy, term_win);
    XFlush(dpy);

    wait_for_window_close(dpy, target);

    /* ICCCM: Withdrawn -> Normal is done simply by mapping the window again. */
    XMapWindow(dpy, term_win);
    /* _NET_MOVERESIZE_WINDOW: gravity 0 (use the window's own), source
     * indication 2 (pager/tool), x/y/width/height all present (bits 8-11). */
    send_client_message(dpy, term_win, root, net_moveresize_window,
                         (2 << 12) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11),
                         term_x, term_y, client_w, client_h);
    send_client_message(dpy, term_win, root, net_active_window, 2, 0, 0, 0, 0);
    XFlush(dpy);

    int status;
    waitpid(child, &status, WNOHANG); /* best-effort reap; may be long gone */
    XCloseDisplay(dpy);
    return 0;
}
