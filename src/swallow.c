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
 * Before hiding, the new window is moved and resized (_NET_MOVERESIZE_WINDOW)
 * to occupy the terminal's exact screen rectangle, so the app visually
 * takes the terminal's place rather than appearing wherever the WM's
 * placement policy would otherwise put it.
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
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_CANDIDATES 16

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

/* Wait for the next top-level window to be created and mapped. Blocks
 * indefinitely: whatever swallow launched may exit long before the real
 * window shows up (see file header comment), so there's no exit condition
 * to race against other than a window actually appearing. */
static Window wait_for_target_window(Display *dpy, Window root) {
    Window candidates[MAX_CANDIDATES];
    int ncandidates = 0;

    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);

        if (ev.type == CreateNotify) {
            XCreateWindowEvent *ce = &ev.xcreatewindow;
            if (ce->parent != root || ce->override_redirect)
                continue;

            if (ncandidates < MAX_CANDIDATES) {
                candidates[ncandidates++] = ce->window;
                /* Select directly on the window (not just SubstructureNotify
                 * on root) so we keep tracking it after the WM reparents it
                 * into a frame. */
                XSelectInput(dpy, ce->window, StructureNotifyMask);
            }
        } else if (ev.type == MapNotify) {
            for (int i = 0; i < ncandidates; i++)
                if (candidates[i] == ev.xmap.window)
                    return ev.xmap.window;
        }
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
    if (argc < 2) {
        fprintf(stderr, "usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

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
        execvp(argv[1], &argv[1]);
        fprintf(stderr, "swallow: exec %s: %s\n", argv[1], strerror(errno));
        _exit(127);
    }

    Window target = wait_for_target_window(dpy, root);

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

    /* Make the new window occupy the exact spot the terminal was in. */
    send_client_message(dpy, target, root, net_moveresize_window,
                         (2 << 12) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11),
                         term_x, term_y, client_w, client_h);

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
