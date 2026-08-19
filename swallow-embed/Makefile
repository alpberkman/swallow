CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

CFLAGS   += $(shell $(PKG_CONFIG) --cflags x11)
LIBS     := $(shell $(PKG_CONFIG) --libs x11)

SRC     := swallow-embed.c
BINNAME := swallow-embed
OUTDIR  := ../bin
BIN     := $(OUTDIR)/$(BINNAME)

PREFIX  ?= $(HOME)/.local
BINDIR  := $(PREFIX)/bin

.PHONY: all run clean install uninstall

all: $(BIN)

$(BIN): $(SRC) | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

$(OUTDIR):
	mkdir -p $(OUTDIR)

run: $(BIN)
	./$(BIN) xterm

clean:
	rm -f $(BIN)

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BINNAME)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BINNAME)
