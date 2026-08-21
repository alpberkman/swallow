/* swallow-embed: reparents a launched app's window into the window
 * that is currently active (normally, the terminal this runs from).
 *
 * Usage: swallow-embed [-s|--shift] [-c|--ctrl] [-a|--alt] [-S|--super] 
 * [-q|--quit-key <key>] [-k|--kill] [-t|--timeout <n>] <command> [args...]
 */

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <poll.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <getopt.h>

#define ERR(...) do { fprintf(stderr, __VA_ARGS__); _exit(1); } while (0)
#define CLAMP(v, lo, hi) ((v) < (lo) ? (lo) : (v) > (hi) ? (hi) : (v))

#define DEFAULT_TIMEOUT_SEC 3
#define MAX_TIMEOUT_SEC 15

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

/* Asks window to close via WM_DELETE_WINDOW, if it advertises support
 * for that protocol; otherwise falls back to XKillClient, since a
 * ClientMessage the window never listens for would otherwise just be
 * silently ignored forever. */
static void XCloseWindow(Display *dpy, Window window) {
    Atom wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    Atom wm_protocols = XInternAtom(dpy, "WM_PROTOCOLS", False);

    Atom *protocols = NULL;
    int nprotocols = 0;
    int supports_delete = 0;
    if (XGetWMProtocols(dpy, window, &protocols, &nprotocols)) {
        for (int i = 0; i < nprotocols; i++) {
            if (protocols[i] == wm_delete) { supports_delete = 1; break; }
        }
        XFree(protocols);
    }

    if (supports_delete) {
        XEvent msg = {0};
        msg.xclient.type = ClientMessage;
        msg.xclient.window = window;
        msg.xclient.message_type = wm_protocols;
        msg.xclient.format = 32;
        msg.xclient.data.l[0] = (long)wm_delete;
        msg.xclient.data.l[1] = CurrentTime;
        XSendEvent(dpy, window, False, NoEventMask, &msg);
    } else {
        XKillClient(dpy, window);
    }
    /* Flush so this isn't lost if the caller exits right after. */
    XFlush(dpy);
}

/* Waits for dpy to have an event ready, up to deadline (0 = forever).
 * Checks XPending() first since Xlib may already have events buffered
 * with nothing left to read on the fd. Returns 0 on timeout. */
static int XWaitEvent(Display *dpy, time_t deadline) {
    while (!XPending(dpy)) {
        int timeout_ms = -1; /* poll()'s "block forever" */
        if (deadline) {
            time_t remaining = deadline - time(NULL);
            if (remaining <= 0) return 0;
            timeout_ms = (int)(remaining * 1000);
        }

        struct pollfd pfd = { .fd = ConnectionNumber(dpy), .events = POLLIN };
        if (poll(&pfd, 1, timeout_ms) == 0) return 0;
    }
    return 1;
}

/* Forks and execs path with argv, then waits for its window. Tracks
 * every new window, not just the first, since some apps (e.g. Kate)
 * create a throwaway window before their real one. Marks each one
 * override_redirect before it maps, so the WM leaves it alone. Gives
 * up and returns None after timeout_sec seconds (0 = forever). */
static Window XSpawnChild(Display *dpy, Window window, const char *path, char *argv[], int timeout_sec) {
    pid_t pid = fork();
    if (pid < 0)
        return None;
    if (pid == 0) {
        execvp(path, argv);
        _exit(127);
    }

    time_t deadline = timeout_sec > 0 ? time(NULL) + timeout_sec : 0;

    for (;;) {
        if (!XWaitEvent(dpy, deadline))
            return None;

        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == CreateNotify) {
            Window w = ev.xcreatewindow.window;
            XWindowAttributes wa;
            if (w == window || !XGetWindowAttributes(dpy, w, &wa) || wa.override_redirect)
                continue;
            XSetWindowAttributes swa = { .override_redirect = True };
            XChangeWindowAttributes(dpy, w, CWOverrideRedirect, &swa);
            XSelectInput(dpy, w, StructureNotifyMask);
        } else if (ev.type == MapNotify && ev.xmap.event == ev.xmap.window) {
            return ev.xmap.window;
        }
    }
}

/* Reparents child into parent, fills parent with it, and maps it.
 * Resizes child to match whenever parent is resized. Blocks until
 * child closes, whether on its own or via the quit hotkey. If kill
 * is set, closes parent too once child is gone. */
static void XEmbedChild(Display *dpy, Window parent, Window child, int kill) {
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
            if (ev.xdestroywindow.window == child) {
                if (kill) XCloseWindow(dpy, parent);
                return;
            }
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
                /* Focusing right after XMapWindow() can race a window
                 * that reparenting briefly unmapped again (BadMatch,
                 * dropped by ignore_error()), so wait for MapNotify. */
                XSetInputFocus(dpy, child, RevertToParent, CurrentTime);
            break;
        }
    }
}

/* Grabs modifiers+key on window as the quit hotkey, and subscribes to
 * new-window events on root so the app's window can be found. Returns
 * 0 if key has no keycode on the current keyboard, since XGrabKey
 * with keycode 0 grabs nothing and would silently no-op the hotkey. */
static int XSetQuit(Display *dpy, Window root, Window window, unsigned int modifiers, const char *key) {
    KeyCode code = XKeysymToKeycode(dpy, XStringToKeysym(key));
    if (code == 0)
        return 0;
    XGrabKey(dpy, code, modifiers, window, True, GrabModeAsync, GrabModeAsync);
    XSelectInput(dpy, window, KeyPressMask | StructureNotifyMask);
    XSelectInput(dpy, root, SubstructureNotifyMask);
    return 1;
}

static void usage(const char *prog) {
    printf(
        "usage: %s [-h|--help] [-s|--shift] [-c|--ctrl] [-a|--alt] [-S|--super] "
        "[-q|--quit-key <key>] [-k|--kill] [-t|--timeout <n>] <command> [args...]\n"
        "  quit hotkey modifiers default to --ctrl alone if none are given\n"
        "  -q, --quit-key takes an X11 keysym name (default: q)\n"
        "  -k, --kill closes the terminal too, once the app's window closes\n"
        "  -t, --timeout <n> gives up if no window appears within n seconds\n"
        "                    (default %d; 0 waits forever; capped at %d)\n",
        prog, DEFAULT_TIMEOUT_SEC, MAX_TIMEOUT_SEC);
}

static struct option long_opts[] = {
    {"help", no_argument, NULL, 'h'},
    {"shift", no_argument, NULL, 's'},
    {"ctrl", no_argument, NULL, 'c'},
    {"alt", no_argument, NULL, 'a'},
    {"super", no_argument, NULL, 'S'},
    {"quit-key", required_argument, NULL, 'q'},
    {"kill", no_argument, NULL, 'k'},
    {"timeout", required_argument, NULL, 't'},
    {0},
};

int main(int argc, char *argv[]) {
    Display *dpy;
    Window root, term_win, child;
    unsigned int quit_mods = 0;
    const char *quit_key = "q";
    int want_kill = 0;
    int timeout_sec = DEFAULT_TIMEOUT_SEC;

    XSetErrorHandler(ignore_error);

    int c;
    /* Leading '+' stops at the first non-option arg (the command to
     * launch), since its flags aren't ours to parse. */
    while ((c = getopt_long(argc, argv, "+hscaSq:kt:", long_opts, NULL)) != -1) {
        switch (c) {
        case 'h': usage(argv[0]); return 0;
        case 's': quit_mods |= ShiftMask; break;
        case 'c': quit_mods |= ControlMask; break;
        case 'a': quit_mods |= Mod1Mask; break;
        case 'S': quit_mods |= Mod4Mask; break;
        case 'q': quit_key = optarg; break;
        case 'k': want_kill = 1; break;
        case 't': timeout_sec = CLAMP(atoi(optarg), 0, MAX_TIMEOUT_SEC); break;
        default: usage(argv[0]); return 1;
        }
    }

    if (quit_mods == 0)
        quit_mods = ControlMask;

    if (XStringToKeysym(quit_key) == NoSymbol)
        ERR("%s: unknown --quit-key '%s'\n", argv[0], quit_key);

    if (optind >= argc) {
        usage(argv[0]);
        return 1;
    }
    
    char **cmd_argv = &argv[optind];

    if ((dpy = XOpenDisplay(NULL)) == NULL)
        ERR("%s: cannot open display\n", argv[0]);

    root = DefaultRootWindow(dpy);
    if ((term_win = XGetActiveWindow(dpy, root)) == None)
        ERR("%s: no active window\n", argv[0]);

    if (!XSetQuit(dpy, root, term_win, quit_mods, quit_key))
        ERR("%s: no keycode for --quit-key '%s'\n", argv[0], quit_key);

    child = XSpawnChild(dpy, term_win, cmd_argv[0], cmd_argv, timeout_sec);
    if (child == None)
        ERR("%s: timed out after %ds waiting for a window from %s\n", argv[0], timeout_sec, cmd_argv[0]);

    XEmbedChild(dpy, term_win, child, want_kill);

    return 0;
}
