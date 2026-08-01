CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

X11_CFLAGS := $(shell $(PKG_CONFIG) --cflags x11)
X11_LIBS   := $(shell $(PKG_CONFIG) --libs x11)

BINS := fork_exec_helper phantom_window_helper geom_trace_helper create_trace_helper

.PHONY: all clean

all: $(BINS)

fork_exec_helper: fork_exec_helper.c
	$(CC) $(CFLAGS) -o $@ $<

phantom_window_helper: phantom_window_helper.c
	$(CC) $(CFLAGS) $(X11_CFLAGS) -o $@ $< $(X11_LIBS)

geom_trace_helper: geom_trace_helper.c
	$(CC) $(CFLAGS) $(X11_CFLAGS) -o $@ $< $(X11_LIBS)

create_trace_helper: create_trace_helper.c
	$(CC) $(CFLAGS) $(X11_CFLAGS) -o $@ $< $(X11_LIBS)

clean:
	rm -f $(BINS)
