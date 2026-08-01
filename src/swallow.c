/*
 * swallow -- run a GUI app from a terminal, hide the terminal while the
 * app's window is open, and restore it when the app closes.
 *
 * Usage: swallow <command> [args...]
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

/* EWMH source-indication value for "pager/tool" senders. */
#define SRC_TOOL 2

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

/* strtol(), rejecting non-numeric input, trailing garbage, and overflow. */
static int parse_long(const char *s, long *out) {
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if(end == s || *end != '\0' || errno == ERANGE)
        return 0;
    *out = v;
    return 1;
}

/* Falls back to fallback when v <= 0. */
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

/* Closes win via WM_DELETE_WINDOW sent directly to it, not routed through
 * the WM (which no longer manages win by the time --kill calls this).
 * Falls back to XKillClient if win never registered the protocol via
 * WM_PROTOCOLS. */
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

/* win's root-relative screen geometry, using its decoration frame (one
 * level under root) if it has one. */
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

/* win's decoration insets (_NET_FRAME_EXTENTS); zero if unpublished. */
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

/* Places/sizes a create-notified candidate window before it
 * maps, to avoid it flashing into the WM's default placement/size first.
 * Applied to every candidate, not just the confirmed target (which isn't
 * known until MapNotify; harmless for one that never maps). mask uses
 * XConfigureWindow's CWX/CWY/CWWidth/CWHeight bits; zero means no pre-map
 * placement (--default, or no placement flags). */
static void apply_pre_map_placement(Display *dpy, Window win, XWindowChanges wc, unsigned int mask) {
    if(!mask)
        return;

    XConfigureWindow(dpy, win, mask, &wc);

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
            /* PMinSize/PMaxSize, not just PSize: pins min==max so the WM
             * clamps the app's own pre-map resize too, not just our initial
             * one. Superseded by the app's real hints shortly after
             * mapping, so the window isn't left stuck at this size. */
            hints.flags |= PSize | PMinSize | PMaxSize;
            hints.width = wc.width;
            hints.height = wc.height;
            hints.min_width = hints.max_width = wc.width;
            hints.min_height = hints.max_height = wc.height;
        }
        XSetWMNormalHints(dpy, win, &hints);
    }
}

/* Waits for the next top-level window to be created and mapped, up to
 * timeout_sec seconds (0 = forever). Returns None on timeout. Tracks every
 * qualifying candidate concurrently, not just the first: some apps (e.g.
 * Kate) create a non-override-redirect helper window before their real
 * one, and only self-addressed MapNotify events reach us (see below), so
 * committing to just the first candidate could wait on the wrong window. */
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

                /* Selects directly so tracking survives reparenting, and
                 * MapNotify arrives self-addressed. */
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
            /* remaining <= MAX_TIMEOUT_SEC, so this can't overflow int. */
            timeout_ms = (int)(remaining * 1000);
        }

        /* EINTR just loops back around and re-checks the deadline. */
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        if(poll(&pfd, 1, timeout_ms) == 0)
            return None;
    }
}

/* Waits for target to close. If track_geometry (--remain), keeps out_attrs
 * and out_extents updated to target's current frame geometry/insets on
 * every ConfigureNotify, since target can't be queried once it's gone. */
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

/* Parses optarg into var via parse_long(), failing with msg if that fails
 * or ok (checked after parsing, so it can reference var) is false. Only
 * valid inside the getopt_long switch below: relies on optarg and returns
 * 1 from main() on failure. */
#define PARSE_ARG(var, ok, msg) do { \
        if(!parse_long(optarg, &(var)) || !(ok)) { \
            fprintf(stderr, "swallow: " msg "\n"); \
            return 1; \
        } \
    } while(0)

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
            PARSE_ARG(val_x, 1, "-x/--x requires a numeric argument");
            have_x = 1;
            break;
        case 'y':
            PARSE_ARG(val_y, 1, "-y/--y requires a numeric argument");
            have_y = 1;
            break;
        case 'w':
            PARSE_ARG(val_w, val_w > 0, "-w/--width requires a positive numeric argument");
            have_w = 1;
            break;
        case 'l':
            PARSE_ARG(val_l, val_l > 0, "-l/--length requires a positive numeric argument");
            have_l = 1;
            break;
        case 't':
            PARSE_ARG(timeout_sec, timeout_sec >= 0, "-t/--timeout requires a non-negative numeric argument");
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

    /* Saved before withdrawing forgets it; also feeds the pre-map placement
     * passed into wait_for_target_window below. */
    XWindowAttributes term_attrs;
    get_window_geometry(dpy, term_win, root, &term_attrs);

    /* _NET_MOVERESIZE_WINDOW's width/height set the *client* area, not the
     * decorated footprint, so shrink by the terminal's own insets. Reused
     * for the terminal's restore too. */
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

    /* Fullscreen is an EWMH *state* layered on top, not a replacement, so
     * normal-state geometry is (re)sent regardless of --full-screen -- a
     * fallback in case the pre-map XConfigureWindow/hint got ignored.
     * pl_mask's CWX/CWY/CWWidth/CWHeight bits happen to align with
     * _NET_MOVERESIZE_WINDOW's presence-flag bits (8-11), so pl_mask << 8
     * produces them directly -- coincidental, don't rely on it elsewhere. */
    if(pl_mask) {
        send_client_message(dpy, target, root, net_moveresize_window,
                             (SRC_TOOL << 12) | (pl_mask << 8),
                             pl_wc.x, pl_wc.y, pl_wc.width, pl_wc.height);
    }

    if(want_fullscreen) {
        Atom net_wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
        Atom net_wm_state_fullscreen = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
        /* _NET_WM_STATE: action=1 (add), property=_NET_WM_STATE_FULLSCREEN. */
        send_client_message(dpy, target, root, net_wm_state,
                             1, (long)net_wm_state_fullscreen, 0, SRC_TOOL, 0);
    }

    /* --remain: track target's geometry/insets as it moves, so the terminal
     * can take its place once it closes. Set immediately in case target
     * closes before its first ConfigureNotify arrives. */
    frame_extents_t remain_extents;
    memcpy(remain_extents, extents, sizeof(extents));
    if(want_remain) {
        get_window_geometry(dpy, target, root, &term_attrs);
        get_frame_extents(dpy, target, net_frame_extents, remain_extents);
    }

    /* Unmap, not iconify: ICCCM Normal -> Withdrawn, drops it from the
     * taskbar/pager instead of leaving a minimized entry. */
    XUnmapWindow(dpy, term_win);
    XFlush(dpy);

    wait_for_window_close(dpy, root, target, net_frame_extents, want_remain,
                           &term_attrs, remain_extents);

    /* --kill: skip the restore and close the terminal instead. */
    if(want_kill) {
        close_window(dpy, term_win, wm_protocols, wm_delete_window);
        XFlush(dpy);
        int status;
        waitpid(child, &status, WNOHANG);
        XCloseDisplay(dpy);
        return 0;
    }

    /* Restore geometry: target's last spot for --remain, else the terminal's
     * own original spot -- term_attrs already holds whichever applies. Must
     * convert to a client size using target's OWN insets (remain_extents),
     * not the terminal's, or repeated --occupy + --remain cycles slowly
     * drift the terminal's size. */
    int restore_x = term_attrs.x, restore_y = term_attrs.y;
    int restore_w = clamp_positive(term_attrs.width - remain_extents[EXT_LEFT] - remain_extents[EXT_RIGHT], term_attrs.width);
    int restore_h = clamp_positive(term_attrs.height - remain_extents[EXT_TOP] - remain_extents[EXT_BOTTOM], term_attrs.height);

    /* XMoveResizeWindow before mapping: Openbox otherwise remaps a withdrawn
     * window straight back to its pre-unmap spot first, ignoring a
     * PPosition hint or _NET_MOVERESIZE_WINDOW while withdrawn, then jumps
     * to the restore spot a moment later. This is the same mechanism a
     * client uses to set its own first-map geometry, so Openbox honors it
     * directly instead. XSync confirms it lands before mapping. */
    XMoveResizeWindow(dpy, term_win, restore_x, restore_y, restore_w, restore_h);
    XSync(dpy, False);

    /* Belt-and-braces PPosition hint for WMs that run real placement policy
     * on remap, unlike Openbox above. Position only, not size: a size hint
     * here gets rounded to the window's own resize increment (e.g. xterm's
     * character cells), shrinking it a little on every restore -- size
     * stays with the _NET_MOVERESIZE_WINDOW call below. Read-modify-write
     * since term_win may carry other hints that must survive. */
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
    /* Fallback if the WM ignored the pre-map hint above. */
    send_client_message(dpy, term_win, root, net_moveresize_window,
                         (SRC_TOOL << 12) | ((CWXY | CWWH) << 8),
                         restore_x, restore_y, restore_w, restore_h);
    send_client_message(dpy, term_win, root, net_active_window, SRC_TOOL, 0, 0, 0, 0);
    XFlush(dpy);

    int status;
    waitpid(child, &status, WNOHANG); /* best-effort reap; may be long gone */
    XCloseDisplay(dpy);
    return 0;
}
