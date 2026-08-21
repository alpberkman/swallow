CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

CFLAGS   += $(shell $(PKG_CONFIG) --cflags x11 xrandr)
LIBS     := $(shell $(PKG_CONFIG) --libs x11 xrandr)

SRC     := mwm.c
BINNAME := mwm
OUTDIR  := ../bin
BIN     := $(OUTDIR)/$(BINNAME)

PREFIX  ?= $(HOME)/.local
BINDIR  := $(PREFIX)/bin

SCRIPTNAME := swallow-wm
SCRIPTSRC  := swallow-wm.sh

.PHONY: all run clean install uninstall

all: $(BIN)

$(BIN): $(SRC) | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

$(OUTDIR):
	mkdir -p $(OUTDIR)

run: $(BIN)
	./swallow-wm.sh

clean:
	rm -f $(BIN)

# swallow-wm.sh looks up ../bin/mwm from its own folder. This still
# finds mwm here, because both files install into the same $(BINDIR).
install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BINNAME)
	install -Dm755 $(SCRIPTSRC) $(DESTDIR)$(BINDIR)/$(SCRIPTNAME)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BINNAME) $(DESTDIR)$(BINDIR)/$(SCRIPTNAME)
