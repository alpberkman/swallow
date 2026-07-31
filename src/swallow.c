/*
 * swallow -- run a GUI app from a terminal, hide the terminal while the
 * app's window is open, and bring the terminal back when it closes.
 *
 * Usage: swallow <command> [args...]
 *
 * The terminal is whatever window is active (_NET_ACTIVE_WINDOW) when
 * swallow starts. The launched command is put in its own process group; any
 * new top-level window is matched against that group via XRes
 * (XResQueryClientIds), which maps a window straight to its owning PID.
 * Matching on the process group rather than the launched PID itself is what
 * makes this survive apps that fork+exec (launcher scripts, double-fork
 * daemonizing): the process swallow started can exit and reparent to init
 * before the real window ever appears, but its process group id doesn't
 * change, so the window it eventually creates still matches.
 *
 * The terminal is hidden by unmapping it (ICCCM Normal -> Withdrawn), which
 * drops it from the taskbar/pager entirely -- not just iconify, which would
 * leave a minimized entry behind. It's restored by mapping it again
 * (Withdrawn -> Normal) and focusing it via _NET_ACTIVE_WINDOW.
 */

#define _DEFAULT_SOURCE
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/XRes.h>

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_CANDIDATES 16

static int x_error_handler(Display *dpy, XErrorEvent *e) {
    (void)dpy;
    (void)e;
    return 0; /* don't let a stray error (e.g. a since-destroyed window) kill us */
}

static pid_t get_pgid_of_pid(pid_t pid) {
    char path[64], buf[4096];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0)
        return -1;
    buf[n] = '\0';

    /* Fields: pid (comm) state ppid pgrp ...  comm may contain spaces/parens. */
    char *paren = strrchr(buf, ')');
    int pgrp;
    if (!paren || sscanf(paren + 1, "%*s %*d %d", &pgrp) != 1)
        return -1;
    return (pid_t)pgrp;
}

/* Ask the X server which PID owns a window's connection. */
static pid_t query_window_pid(Display *dpy, Window w) {
    XResClientIdSpec spec = {.client = w, .mask = XRES_CLIENT_ID_PID_MASK};
    long num_ids = 0;
    XResClientIdValue *ids = NULL;

    /* Unlike most Xlib Status-returning calls, success here is 0 (X core
     * protocol Success); the return value isn't a reliable failure signal. */
    XResQueryClientIds(dpy, 1, &spec, &num_ids, &ids);
    if (!ids)
        return -1;

    pid_t pid = -1;
    for (long i = 0; i < num_ids; i++) {
        if (ids[i].spec.mask & XRES_CLIENT_ID_PID_MASK) {
            pid_t p = XResGetClientPid(&ids[i]);
            if (p > 0) {
                pid = p;
                break;
            }
        }
    }
    XResClientIdsDestroy(num_ids, ids);
    return pid;
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

static void send_client_message(Display *dpy, Window target, Window root, Atom type, long l0) {
    XEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.xclient.type = ClientMessage;
    ev.xclient.window = target;
    ev.xclient.message_type = type;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = l0;
    XSendEvent(dpy, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &ev);
}

/* Wait for a top-level window whose owning process is in target_pgid to be
 * created and mapped. This blocks indefinitely by design: the process
 * swallow directly launched may already be gone (reparented to init) by
 * the time the real window shows up, so there's no exit condition to race
 * against other than the window itself appearing. */
static Window wait_for_target_window(Display *dpy, Window root, pid_t target_pgid) {
    Window candidates[MAX_CANDIDATES];
    int ncandidates = 0;

    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);

        if (ev.type == CreateNotify) {
            XCreateWindowEvent *ce = &ev.xcreatewindow;
            if (ce->parent != root || ce->override_redirect)
                continue;

            pid_t pid = query_window_pid(dpy, ce->window);
            if (pid <= 0 || get_pgid_of_pid(pid) != target_pgid)
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

    int ev_base, err_base;
    if (!XResQueryExtension(dpy, &ev_base, &err_base)) {
        fprintf(stderr, "swallow: X Resource (XRes) extension not available\n");
        return 1;
    }

    Window root = DefaultRootWindow(dpy);
    Atom net_active_window = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);

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
        setpgid(0, 0); /* own process group: see file header comment */
        execvp(argv[1], &argv[1]);
        fprintf(stderr, "swallow: exec %s: %s\n", argv[1], strerror(errno));
        _exit(127);
    }

    Window target = wait_for_target_window(dpy, root, /* target_pgid = */ child);

    /* Unmapping (rather than iconifying) makes the terminal actually
     * disappear: ICCCM's Normal -> Withdrawn transition, which drops it
     * from the taskbar/pager entirely instead of leaving a minimized entry. */
    XUnmapWindow(dpy, term_win);
    XFlush(dpy);

    wait_for_window_close(dpy, target);

    /* ICCCM: Withdrawn -> Normal is done simply by mapping the window again. */
    XMapWindow(dpy, term_win);
    send_client_message(dpy, term_win, root, net_active_window, 2);
    XFlush(dpy);

    int status;
    waitpid(child, &status, WNOHANG); /* best-effort reap; may be long gone */
    XCloseDisplay(dpy);
    return 0;
}
