CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

CFLAGS   += $(shell $(PKG_CONFIG) --cflags x11)
LIBS     := $(shell $(PKG_CONFIG) --libs x11)

PREFIX   ?= $(HOME)/.local
BINDIR   := $(PREFIX)/bin

SRC     := src/swallow-generic.c
BINNAME := swallow-generic
OUTDIR  := bin
BIN     := $(OUTDIR)/$(BINNAME)

AUTONAME := swallow
AUTOSRC  := swallow-auto.sh
I3NAME   := swallow-i3
I3SRC    := swallow-i3/swallow-i3.sh

BASHRC              := $(HOME)/.bashrc
SWALLOW_APPS_LINE    := SWALLOW_APPS=()
SWALLOW_FLAGS_LINE   := SWALLOW_FLAGS="--remain --occupy --timeout 3"
SHELL_INTEGRATION    := $(CURDIR)/shell-integration.sh
SHELL_INTEGRATION_LINE := source $(SHELL_INTEGRATION)

.PHONY: all clean install install-files uninstall test deb

all: $(BIN)

$(BIN): $(SRC) | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

$(OUTDIR):
	mkdir -p $(OUTDIR)

clean:
	rm -f $(BIN)
	$(MAKE) -C tests clean

# Split from `install` so packaging (debian/rules) can install just the
# binary/scripts into a DESTDIR without also touching a real ~/.bashrc --
# there's no single right "the user" to wire shell integration for from a
# postinst script, unlike here where $(BASHRC) unambiguously means yours.
install-files: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BINNAME)
	install -Dm755 $(AUTOSRC) $(DESTDIR)$(BINDIR)/$(AUTONAME)
	install -Dm755 $(I3SRC) $(DESTDIR)$(BINDIR)/$(I3NAME)

# The .bashrc line is a `source`, not a raw append of shell-integration.sh's
# own code -- sourcing keeps its BASH_SOURCE-relative lookup of
# swallow-auto.sh resolving to this repo, instead of to wherever .bashrc
# happens to live. grep -qxF guards against appending the same line again
# on repeat installs.
#
# SWALLOW_APPS=() and a default SWALLOW_FLAGS=... are added above it (each
# only if no assignment to that name exists at all yet -- a plain -qxF
# check would re-add them every time and stomp whatever was since edited)
# as somewhere for you to list the apps shell-integration.sh should wrap
# and the flags to launch them with; it's your .bashrc from here, not this
# repo's.
install: install-files
	grep -qE '^SWALLOW_APPS=' $(BASHRC) 2>/dev/null || \
		echo '$(SWALLOW_APPS_LINE)' >> $(BASHRC)
	grep -qE '^SWALLOW_FLAGS=' $(BASHRC) 2>/dev/null || \
		echo '$(SWALLOW_FLAGS_LINE)' >> $(BASHRC)
	grep -qxF '$(SHELL_INTEGRATION_LINE)' $(BASHRC) 2>/dev/null || \
		echo '$(SHELL_INTEGRATION_LINE)' >> $(BASHRC)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BINNAME) $(DESTDIR)$(BINDIR)/$(AUTONAME) $(DESTDIR)$(BINDIR)/$(I3NAME)

test: $(BIN)
	$(MAKE) -C tests
	tests/run_tests.sh

# dpkg-buildpackage drops the .deb (and .buildinfo/.changes) one directory
# above this one -- that's its own convention, not something to fight.
# -us -uc: don't GPG-sign, irrelevant for a local/unpublished build.
deb:
	dpkg-buildpackage -us -uc -b
