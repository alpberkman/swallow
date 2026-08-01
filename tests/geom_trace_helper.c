/* Selects StructureNotify on a given window and prints every ConfigureNotify
 * width/height it gets, one per line, until killed. Used to catch a
 * restore-time flash: a WM (e.g. Openbox) briefly remapping the terminal at
 * its old size/position before correcting it a few ms later, which a
 * before/after geometry check alone can't see since it only samples the
 * final state. Width/height (not x/y) are what's checked by the caller,
 * since ConfigureNotify's x/y are parent-relative unless synthetic and so
 * aren't directly comparable to a root-relative geometry -- size doesn't
 * have that ambiguity. */
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <window-id>\n", argv[0]);
        return 1;
    }
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "geom_trace_helper: cannot open display\n");
        return 1;
    }
    Window win = (Window)strtoul(argv[1], NULL, 0);
    XSelectInput(dpy, win, StructureNotifyMask);
    XFlush(dpy);
    for (;;) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == ConfigureNotify) {
            printf("%d,%d\n", ev.xconfigure.width, ev.xconfigure.height);
            fflush(stdout);
        }
    }
}
