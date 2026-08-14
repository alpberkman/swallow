/* mwm: a minimal kiosk window manager
 * - The newest window fills the screen.
 * - Ctrl+Q closes the window under the pointer.
 * - A screen size change resizes the top window.
 * - When the top window closes, the window under the pointer becomes
 *   the new top window.*/

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/Xrandr.h>

static Window top;

static void set_fullscreen(Display *dpy, Window w, int screen_w, int screen_h) {
    Atom net_wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
    Atom fullscreen = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
    XChangeProperty(dpy, w, net_wm_state, XA_ATOM, 32, PropModeReplace,
            (unsigned char *)&fullscreen, 1);
    XMoveResizeWindow(dpy, w, 0, 0, screen_w, screen_h);
}

static int ignore_error(Display *dpy, XErrorEvent *e) {
    (void)dpy; (void)e;
    return 0;
}

/* Send WM_DELETE_WINDOW if the client supports it. If not, force the
 * close with XKillClient. */
static void close_window(Display *dpy, Window w) {
    Atom wm_protocols = XInternAtom(dpy, "WM_PROTOCOLS", False);
    Atom wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    Atom *protocols;
    int n;
    int supports_delete = 0;

    if(XGetWMProtocols(dpy, w, &protocols, &n)) {
        for(int i = 0; i < n; i++) {
            if(protocols[i] == wm_delete) {
                supports_delete = 1;
                break;
            }
        }
        XFree(protocols);
    }

    if(supports_delete) {
        XEvent msg = {0};
        msg.xclient.type = ClientMessage;
        msg.xclient.window = w;
        msg.xclient.message_type = wm_protocols;
        msg.xclient.format = 32;
        msg.xclient.data.l[0] = wm_delete;
        msg.xclient.data.l[1] = CurrentTime;
        XSendEvent(dpy, w, False, NoEventMask, &msg);
    } else {
        XKillClient(dpy, w);
    }
}

int main(void) {
    Display *dpy;
    Window root;
    int screen_w, screen_h;
    int rr_event_base, rr_error_base;
    XEvent ev;

    if(!(dpy = XOpenDisplay(0x0))) return 1;

    root = DefaultRootWindow(dpy);
    screen_w = DisplayWidth(dpy, DefaultScreen(dpy));
    screen_h = DisplayHeight(dpy, DefaultScreen(dpy));

    XSetErrorHandler(ignore_error);
    XSelectInput(dpy, root, SubstructureRedirectMask | SubstructureNotifyMask);
    XGrabKey(dpy, XKeysymToKeycode(dpy, XStringToKeysym("q")), ControlMask,
            root, True, GrabModeAsync, GrabModeAsync);

    /* A live Xephyr resize sends RRScreenChangeNotify. It does not
     * send a root ConfigureNotify. Track this event. If you do not,
     * screen_w and screen_h stay frozen at their startup values. */
    if(XRRQueryExtension(dpy, &rr_event_base, &rr_error_base))
        XRRSelectInput(dpy, root, RRScreenChangeNotifyMask);

    for(;;) {
        XNextEvent(dpy, &ev);
        switch(ev.type) {
        case ConfigureRequest: {
            XWindowChanges wc;
            wc.border_width = ev.xconfigurerequest.border_width;
            wc.sibling = ev.xconfigurerequest.above;
            wc.stack_mode = ev.xconfigurerequest.detail;

            if(ev.xconfigurerequest.window == top) {
                wc.x = 0;
                wc.y = 0;
                wc.width = screen_w;
                wc.height = screen_h;
            } else {
                wc.x = ev.xconfigurerequest.x;
                wc.y = ev.xconfigurerequest.y;
                wc.width = ev.xconfigurerequest.width;
                wc.height = ev.xconfigurerequest.height;
            }

            XConfigureWindow(dpy, ev.xconfigurerequest.window,
                    ev.xconfigurerequest.value_mask, &wc);
            break;
        }
        case MapRequest: {
            /* Popups, such as menus and tooltips, set
             * override_redirect. They place themselves. Never treat
             * a popup as the new top window. */
            XWindowAttributes wa;
            XGetWindowAttributes(dpy, ev.xmaprequest.window, &wa);
            if(wa.override_redirect) {
                XMapWindow(dpy, ev.xmaprequest.window);
                break;
            }

            top = ev.xmaprequest.window;
            XMapWindow(dpy, top);
            XSetInputFocus(dpy, top, RevertToPointerRoot, CurrentTime);
            set_fullscreen(dpy, top, screen_w, screen_h);
            break;
        }
        case DestroyNotify:
            if(ev.xdestroywindow.window == top) {
                /* The window under the pointer becomes the new top
                 * window. XQueryPointer's child_return gives the
                 * topmost child of root at that position. This is the
                 * window that the old top window covered. */
                Window root_ret, child_ret;
                int rx, ry, wx, wy;
                unsigned int mask;
                XWindowAttributes wa;
                XQueryPointer(dpy, root, &root_ret, &child_ret,
                        &rx, &ry, &wx, &wy, &mask);
                if(child_ret && XGetWindowAttributes(dpy, child_ret, &wa) &&
                        wa.override_redirect)
                    child_ret = None;
                top = child_ret;
                if(top) {
                    XSetInputFocus(dpy, top, RevertToPointerRoot, CurrentTime);
                    set_fullscreen(dpy, top, screen_w, screen_h);
                }
            }
            break;
        case KeyPress:
            if(ev.xkey.subwindow != None)
                close_window(dpy, ev.xkey.subwindow);
            break;
        default:
            /* Not a case label: rr_event_base is a runtime value, not
             * a compile-time constant. */
            if(ev.type == rr_event_base + RRScreenChangeNotify) {
                XRRUpdateConfiguration(&ev);
                screen_w = DisplayWidth(dpy, DefaultScreen(dpy));
                screen_h = DisplayHeight(dpy, DefaultScreen(dpy));
                if(top)
                    XMoveResizeWindow(dpy, top, 0, 0, screen_w, screen_h);
            }
            break;
        }
    }
}
