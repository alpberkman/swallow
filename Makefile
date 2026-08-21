PREFIX   ?= $(HOME)/.local
BINDIR   := $(PREFIX)/bin

BINNAME := swallow-generic
OUTDIR  := bin
BIN     := $(OUTDIR)/$(BINNAME)

EMBEDBIN := $(OUTDIR)/swallow-embed
WMBIN    := $(OUTDIR)/mwm

AUTONAME := swallow-auto
AUTOSRC  := swallow-auto.sh
I3NAME   := swallow-i3
I3SRC    := swallow-i3/swallow-i3.sh
LINKNAME := swallow

BASHRC              := $(HOME)/.bashrc
SWALLOW_APPS_LINE    := SWALLOW_APPS=()
SWALLOW_FLAGS_LINE   := SWALLOW_FLAGS="--ctrl --shift --quit-key q --timeout 15"
SHELL_INTEGRATION    := $(CURDIR)/shell-integration.sh
SHELL_INTEGRATION_LINE := source $(SHELL_INTEGRATION)

.PHONY: all clean install install-files uninstall test deb $(BIN) $(EMBEDBIN) $(WMBIN)

all: $(BIN) $(EMBEDBIN) $(WMBIN)

$(BIN):
	$(MAKE) -C swallow-generic

$(EMBEDBIN):
	$(MAKE) -C swallow-embed

$(WMBIN):
	$(MAKE) -C swallow-wm

clean:
	$(MAKE) -C swallow-generic clean
	$(MAKE) -C swallow-embed clean
	$(MAKE) -C swallow-wm clean
	$(MAKE) -C tests clean

# Separate from `install` so debian/rules can install into a DESTDIR
# without touching a real ~/.bashrc.
install-files: $(BIN) $(EMBEDBIN) $(WMBIN)
	$(MAKE) -C swallow-generic install
	$(MAKE) -C swallow-embed install
	$(MAKE) -C swallow-wm install
	install -Dm755 $(AUTOSRC) $(DESTDIR)$(BINDIR)/$(AUTONAME)
	install -Dm755 $(I3SRC) $(DESTDIR)$(BINDIR)/$(I3NAME)
	ln -sf swallow-embed $(DESTDIR)$(BINDIR)/$(LINKNAME)

# Adds SWALLOW_APPS, SWALLOW_FLAGS, and a source line to ~/.bashrc, each
# only if missing, so re-running install never overwrites edits you've
# made to them. .bashrc sources this repo's copy of
# shell-integration.sh rather than embedding its code.
install: install-files
	grep -qE '^SWALLOW_APPS=' $(BASHRC) 2>/dev/null || \
		echo '$(SWALLOW_APPS_LINE)' >> $(BASHRC)
	grep -qE '^SWALLOW_FLAGS=' $(BASHRC) 2>/dev/null || \
		echo '$(SWALLOW_FLAGS_LINE)' >> $(BASHRC)
	grep -qxF '$(SHELL_INTEGRATION_LINE)' $(BASHRC) 2>/dev/null || \
		echo '$(SHELL_INTEGRATION_LINE)' >> $(BASHRC)

uninstall:
	$(MAKE) -C swallow-generic uninstall
	$(MAKE) -C swallow-embed uninstall
	$(MAKE) -C swallow-wm uninstall
	rm -f $(DESTDIR)$(BINDIR)/$(AUTONAME) $(DESTDIR)$(BINDIR)/$(I3NAME) $(DESTDIR)$(BINDIR)/$(LINKNAME)

test: $(BIN) $(EMBEDBIN) $(WMBIN)
	$(MAKE) -C tests
	tests/test-generic.sh
	tests/test-i3.sh --xephyr swallow-i3/swallow-i3.sh
	tests/test-embed.sh

# Output lands one folder above this one; that's normal dpkg-buildpackage
# behavior. -us -uc skips GPG signing, unneeded for a local build.
deb:
	dpkg-buildpackage -us -uc -b
