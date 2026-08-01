CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

CFLAGS   += $(shell $(PKG_CONFIG) --cflags x11)
LIBS     := $(shell $(PKG_CONFIG) --libs x11)

PREFIX   ?= /usr/local
BINDIR   := $(PREFIX)/bin

SRC     := src/swallow.c
BINNAME := swallow
OUTDIR  := bin
BIN     := $(OUTDIR)/$(BINNAME)

.PHONY: all clean install uninstall test

all: $(BIN)

$(BIN): $(SRC) | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

$(OUTDIR):
	mkdir -p $(OUTDIR)

clean:
	rm -f $(BIN)
	$(MAKE) -C tests clean

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BINNAME)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BINNAME)

test: $(BIN)
	$(MAKE) -C tests
	tests/run_tests.sh
