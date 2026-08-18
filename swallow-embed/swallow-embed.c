/* swallow-embed: reparents a launched app's window into the window
 * that is currently active (normally, the terminal this runs from).
 * Ctrl+Q closes the embedded app.
 *
 * Usage: swallow-embed <command> [args...]
 */

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <unistd.h>
#include <stdio.h>

static Window term_win, child;

static int ignore_error(Display *dpy, XErrorEvent *e) {
    (void)dpy; (void)e;
    return 0;
}

static Window get_active_window(Display *dpy, Window root) {
    Atom prop = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    Atom type;
    int format;
    unsigned long n, after;
    unsigned char *data = NULL;
    Window w = None;

    if (XGetWindowProperty(dpy, root, prop, 0, 1, False, XA_WINDOW,
                &type, &format, &n, &after, &data) == Success && data) {
        if (n >= 1) w = *(Window *)data;
        XFree(data);
    }
    return w;
}

static void close_child(Display *dpy) {
    Atom wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XEvent msg = {0};
    msg.xclient.type = ClientMessage;
    msg.xclient.window = child;
    msg.xclient.message_type = XInternAtom(dpy, "WM_PROTOCOLS", False);
    msg.xclient.format = 32;
    msg.xclient.data.l[0] = (long)wm_delete;
    msg.xclient.data.l[1] = CurrentTime;
    XSendEvent(dpy, child, False, NoEventMask, &msg);
}

/* Finds the launched app's window: the next new top-level window to
 * be mapped. Tracks every created candidate at once, not just the
 * first, since some apps create a throwaway window before their real
 * one. Marks each candidate override_redirect before it maps, so the
 * real WM (i3, Openbox, ...) never gets a MapRequest for it and so
 * never claims it -- without this, the WM always wins the race to
 * reparent it into its own decoration frame first, and this whole
 * program ends up embedding nothing. */
static Window wait_for_target_window(Display *dpy) {
    Window candidates[64];
    int n = 0;

    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == CreateNotify) {
            Window w = ev.xcreatewindow.window;
            XWindowAttributes wa;
            if (w == term_win || !XGetWindowAttributes(dpy, w, &wa) || wa.override_redirect)
                continue;
            if (n < 64) {
                XSetWindowAttributes swa;
                swa.override_redirect = True;
                XChangeWindowAttributes(dpy, w, CWOverrideRedirect, &swa);
                XSelectInput(dpy, w, StructureNotifyMask);
                candidates[n++] = w;
            }
        } else if (ev.type == MapNotify && ev.xmap.event == ev.xmap.window) {
            for (int i = 0; i < n; i++)
                if (candidates[i] == ev.xmap.window) return ev.xmap.window;
        }
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "cannot open display\n");
        return 1;
    }
    XSetErrorHandler(ignore_error);
    Window root = DefaultRootWindow(dpy);

    term_win = get_active_window(dpy, root);
    if (term_win == None) {
        fprintf(stderr, "swallow-embed: no active window\n");
        return 1;
    }

    XWindowAttributes term_attrs;
    XGetWindowAttributes(dpy, term_win, &term_attrs);

    XGrabKey(dpy, XKeysymToKeycode(dpy, XStringToKeysym("q")), ControlMask,
            term_win, True, GrabModeAsync, GrabModeAsync);
    XSelectInput(dpy, term_win, KeyPressMask);
    XSelectInput(dpy, root, SubstructureNotifyMask);

    if (fork() == 0) {
        execvp(argv[1], &argv[1]);
        _exit(127);
    }

    child = wait_for_target_window(dpy);
    XReparentWindow(dpy, child, term_win, 0, 0);
    XMoveResizeWindow(dpy, child, 0, 0, term_attrs.width, term_attrs.height);
    XSelectInput(dpy, child, StructureNotifyMask);
    XMapWindow(dpy, child);
    XSetInputFocus(dpy, child, RevertToParent, CurrentTime);

    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == DestroyNotify && ev.xdestroywindow.window == child)
            return 0;
        if (ev.type == KeyPress)
            close_child(dpy);
    }
}
