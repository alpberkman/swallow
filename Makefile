CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

CFLAGS   += $(shell $(PKG_CONFIG) --cflags x11 xres)
LIBS     := $(shell $(PKG_CONFIG) --libs x11 xres)

PREFIX   ?= /usr/local
BINDIR   := $(PREFIX)/bin

SRC := src/swallow.c
BIN := swallow

.PHONY: all clean install uninstall test

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

clean:
	rm -f $(BIN)
	$(MAKE) -C tests clean

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BIN)

test: $(BIN)
	$(MAKE) -C tests
	tests/run_tests.sh
