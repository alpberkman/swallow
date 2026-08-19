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

#define LENOF(a) (sizeof(a) / sizeof((a)[0]))
#define ERR(...) do { fprintf(stderr, __VA_ARGS__); _exit(1); } while (0)

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

/* Forks and execs path with argv, then waits for its window and returns
 * it. Tracks every new window, not just the first, since some apps
 * (e.g. Kate) create a throwaway window before their real one. Marks
 * each one override_redirect before it maps, so the WM never sees a
 * MapRequest for it and reparents it into a decoration frame first. */
static Window XSpawnChild(Display *dpy, Window window, const char *path, char *argv[]) {
    if (fork() == 0) {
        execvp(path, argv);
        _exit(127);
    }

    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == CreateNotify) {
            Window w = ev.xcreatewindow.window;
            XWindowAttributes wa;
            if (w == window || !XGetWindowAttributes(dpy, w, &wa) || wa.override_redirect)
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

/* Reparents child into parent, resizes it to fill parent, and maps it.
 * Then blocks until child closes on its own, or the close hotkey asks
 * it to close via XCloseWindow. Resizes child again whenever parent
 * is resized. */
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
        case ConfigureNotify:
            if (ev.xconfigure.window == parent)
                XResizeWindow(dpy, child, ev.xconfigure.width, ev.xconfigure.height);
            break;
        case MapNotify:
            if (ev.xmap.window == child)
                /* Wait for the child to actually be viewable before
                 * focusing it. Reparenting can briefly unmap/remap it,
                 * so focusing right after our own XMapWindow() above
                 * can race a not-yet-viewable window (BadMatch, dropped
                 * by ignore_error()). */
                XSetInputFocus(dpy, child, RevertToParent, CurrentTime);
            break;
        }
    }
}

/* Grabs modifiers+key on window as the close hotkey, and subscribes to
 * new-window events on root, so we can find the launched app's window. */
static void XSetQuit(Display *dpy, Window root, Window window, unsigned int modifiers, const char *key) {
    KeyCode code = XKeysymToKeycode(dpy, XStringToKeysym(key));
    XGrabKey(dpy, code, modifiers, window, True, GrabModeAsync, GrabModeAsync);
    XSelectInput(dpy, window, KeyPressMask | StructureNotifyMask);
    XSelectInput(dpy, root, SubstructureNotifyMask);
}

int main(int argc, char *argv[]) {
    Display *dpy;
    Window root, term_win, child;

    XSetErrorHandler(ignore_error);

    if (argc < 2)
        ERR("usage: %s <command> [args...]\n", argv[0]);

    if ((dpy = XOpenDisplay(NULL)) == NULL)
        ERR("%s: cannot open display\n", argv[0]);

    root = DefaultRootWindow(dpy);

    if ((term_win = XGetActiveWindow(dpy, root)) == None)
        ERR("%s: no active window\n", argv[0]);

    XSetQuit(dpy, root, term_win, ControlMask, "q");

    child = XSpawnChild(dpy, term_win, argv[1], &argv[1]);
    XEmbedChild(dpy, term_win, child);

    return 0;
}
