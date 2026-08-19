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
#include <stdlib.h>

#define LENOF(a) (sizeof(a) / sizeof((a)[0]))
#define ERR(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)

static int ignore_error(Display *dpy, XErrorEvent *e) {
    (void)dpy; (void)e;
    return 0;
}

static Window XGetActiveWindow(Display *dpy, Window root) {
    Atom prop = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    Atom type;
    int format;
    unsigned long n, after;
    unsigned char *data = NULL;
    Window w = None;

    if (XGetWindowProperty(dpy, root, prop, 0, 1, False, XA_WINDOW, &type, &format, &n, &after, &data) == Success) {
        if(data != NULL) {
            if(n >= 1) w = *(Window *)data;
            XFree(data);
        }
    }

    return w;
}

static void XCloseWindow(Display *dpy, Window window) {
    Atom wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    Atom wm_protocols = XInternAtom(dpy, "WM_PROTOCOLS", False);
    XEvent msg = {0};
    msg.xclient.type = ClientMessage;
    msg.xclient.window = window;
    msg.xclient.message_type = wm_protocols;
    msg.xclient.format = 32;
    msg.xclient.data.l[0] = (long)wm_delete;
    msg.xclient.data.l[1] = CurrentTime;
    XSendEvent(dpy, window, False, NoEventMask, &msg);
}

/* Finds the launched app's window: the next new top-level window to
 * be mapped. Tracks every created candidate at once, not just the
 * first, since some apps create a throwaway window before their real
 * one. Marks each candidate override_redirect before it maps, so the
 * real WM (i3, Openbox, ...) never gets a MapRequest for it and so
 * never claims it -- without this, the WM always wins the race to
 * reparent it into its own decoration frame first, and this whole
 * program ends up embedding nothing. */
static Window wait_for_target_window(Display *dpy, Window term_win) {
    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == CreateNotify) {
            Window w = ev.xcreatewindow.window;
            XWindowAttributes wa;
            if (w == term_win || !XGetWindowAttributes(dpy, w, &wa) || wa.override_redirect)
                continue;
            XSetWindowAttributes swa;
            swa.override_redirect = True;
            XChangeWindowAttributes(dpy, w, CWOverrideRedirect, &swa);
            XSelectInput(dpy, w, StructureNotifyMask);
        } else if (ev.type == MapNotify && ev.xmap.event == ev.xmap.window) {
            return ev.xmap.window;
        }
    }
}

/* Forks and execs path with argv, then waits for and returns its window. */
static Window XSpawnChild(Display *dpy, Window window, const char *path, char *argv[]) {
    if (fork() == 0) {
        execvp(path, argv);
        _exit(127);
    }
    return wait_for_target_window(dpy, window);
}

/* Reparents child into parent, resizes it to fill parent, maps it, then
 * blocks until child closes (returning normally) or Ctrl+Q is pressed
 * (asking child to close via XCloseWindow). */
static void XEmbedChild(Display *dpy, Window parent, Window child) {
    XWindowAttributes parent_attrs;
    XGetWindowAttributes(dpy, parent, &parent_attrs);
    XReparentWindow(dpy, child, parent, 0, 0);
    XMoveResizeWindow(dpy, child, 0, 0, parent_attrs.width, parent_attrs.height);
    XSelectInput(dpy, child, StructureNotifyMask);
    XMapWindow(dpy, child);

    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        switch (ev.type) {
        case DestroyNotify:
            if (ev.xdestroywindow.window == child)
                return;
            break;
        case KeyPress:
            XCloseWindow(dpy, child);
            break;
        case MapNotify:
            if (ev.xmap.window == child)
                /* Focus only once the child is actually viewable.
                 * Setting it right after our own XMapWindow() above can
                 * race a window that is not viewable yet (BadMatch,
                 * silently dropped by ignore_error()), since reparenting
                 * can itself briefly unmap/remap the window first. */
                XSetInputFocus(dpy, child, RevertToParent, CurrentTime);
            break;
        }
    }
}

/* Grabs Ctrl+<key> on term_win (the close hotkey), and subscribes to
 * new-window events on root, needed to find the launched app's window. */
static void XSetQuit(Display *dpy, Window root, Window window, unsigned int modifiers, const char *key) {
    KeyCode code = XKeysymToKeycode(dpy, XStringToKeysym(key));
    XGrabKey(dpy, code, modifiers, window, True, GrabModeAsync, GrabModeAsync);
    XSelectInput(dpy, window, KeyPressMask);
    XSelectInput(dpy, root, SubstructureNotifyMask);
}

int main(int argc, char *argv[]) {
    Display *dpy;
    Window root, term_win, child;

    XSetErrorHandler(ignore_error);

    if (argc < 2)
        ERR("usage: %s <command> [args...]\n", argv[0]);

    if ((dpy = XOpenDisplay(NULL)) == NULL)
        ERR("cannot open display\n");

    root = DefaultRootWindow(dpy);

    if ((term_win = XGetActiveWindow(dpy, root)) == None)
        ERR("swallow-embed: no active window\n");

    XSetQuit(dpy, root, term_win, ControlMask, "q");

    child = XSpawnChild(dpy, term_win, argv[1], &argv[1]);
    XEmbedChild(dpy, term_win, child);

    return 0;
}
