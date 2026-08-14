CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

CFLAGS   += $(shell $(PKG_CONFIG) --cflags x11)
LIBS     := $(shell $(PKG_CONFIG) --libs x11)

SRC     := swallow-generic.c
BINNAME := swallow-generic
OUTDIR  := ../bin
BIN     := $(OUTDIR)/$(BINNAME)

PREFIX  ?= $(HOME)/.local
BINDIR  := $(PREFIX)/bin

.PHONY: all clean install uninstall

all: $(BIN)

$(BIN): $(SRC) | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

$(OUTDIR):
	mkdir -p $(OUTDIR)

clean:
	rm -f $(BIN)

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BINNAME)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BINNAME)
