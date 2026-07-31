/*
 * Creates a plain top-level window and deliberately never maps it, then
 * launches the real command. Stands in for apps (e.g. Kate, via KDE/Qt)
 * that create a non-override-redirect helper window -- a session-restore
 * prompt, an IME/drag-and-drop proxy, etc. -- before their real one.
 *
 * Used to test that swallow tracks multiple candidate windows rather than
 * committing to the first one it sees: a version that waits only on the
 * first window created would hang here forever, since this phantom window
 * never maps and never closes.
 */
#define _DEFAULT_SOURCE
#include <X11/Xlib.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <command> [args...]\n", argv[0]);
        return 2;
    }

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "phantom_window_helper: cannot open X display\n");
        return 1;
    }
    XCreateSimpleWindow(dpy, DefaultRootWindow(dpy), 0, 0, 1, 1, 0, 0, 0);
    XFlush(dpy);

    usleep(200000); /* give swallow time to see it before the real window shows up */
    execvp(argv[1], &argv[1]);
    perror("phantom_window_helper: execvp");
    return 127;
}
