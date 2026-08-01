CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

X11_CFLAGS := $(shell $(PKG_CONFIG) --cflags x11)
X11_LIBS   := $(shell $(PKG_CONFIG) --libs x11)

OUTDIR := ../bin
BINS   := fork_exec_helper phantom_window_helper geom_trace_helper create_trace_helper

.PHONY: all clean

all: $(addprefix $(OUTDIR)/,$(BINS))

$(OUTDIR):
	mkdir -p $(OUTDIR)

$(OUTDIR)/fork_exec_helper: fork_exec_helper.c | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $<

$(OUTDIR)/phantom_window_helper: phantom_window_helper.c | $(OUTDIR)
	$(CC) $(CFLAGS) $(X11_CFLAGS) -o $@ $< $(X11_LIBS)

$(OUTDIR)/geom_trace_helper: geom_trace_helper.c | $(OUTDIR)
	$(CC) $(CFLAGS) $(X11_CFLAGS) -o $@ $< $(X11_LIBS)

$(OUTDIR)/create_trace_helper: create_trace_helper.c | $(OUTDIR)
	$(CC) $(CFLAGS) $(X11_CFLAGS) -o $@ $< $(X11_LIBS)

clean:
	rm -f $(addprefix $(OUTDIR)/,$(BINS))
