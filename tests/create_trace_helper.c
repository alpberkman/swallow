/* Mirrors swallow's own wait_for_target_window logic (select
 * SubstructureNotify on root, select StructureNotify on each qualifying
 * child at CreateNotify) so a test can observe a new window's real event
 * sequence from the moment it's created -- a bash polling loop via xdotool
 * can't, since its own per-call process-spawn latency is bigger than the
 * whole flash being tested for. Prints one line per event, space-separated,
 * until killed:
 *   create <id> <x>,<y>,<w>,<h>
 *   configure <id> <x>,<y>,<w>,<h>
 *   map <id>
 */
#include <X11/Xlib.h>
#include <stdio.h>

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "create_trace_helper: cannot open display\n");
        return 1;
    }
    Window root = DefaultRootWindow(dpy);
    XSelectInput(dpy, root, SubstructureNotifyMask);
    XFlush(dpy);

    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == CreateNotify) {
            XCreateWindowEvent *ce = &ev.xcreatewindow;
            if (ce->parent != root || ce->override_redirect)
                continue;
            XSelectInput(dpy, ce->window, StructureNotifyMask);
            XFlush(dpy);
            printf("create %lu %d,%d,%d,%d\n", ce->window, ce->x, ce->y, ce->width, ce->height);
            fflush(stdout);
        } else if (ev.type == ConfigureNotify) {
            printf("configure %lu %d,%d,%d,%d\n", ev.xconfigure.window,
                   ev.xconfigure.x, ev.xconfigure.y, ev.xconfigure.width, ev.xconfigure.height);
            fflush(stdout);
        } else if (ev.type == MapNotify && ev.xmap.event == ev.xmap.window) {
            printf("map %lu\n", ev.xmap.window);
            fflush(stdout);
        }
    }
}
