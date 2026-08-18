CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
PKG_CONFIG ?= pkg-config

CFLAGS   += $(shell $(PKG_CONFIG) --cflags x11)
LIBS     := $(shell $(PKG_CONFIG) --libs x11)

SRC     := swallow-embed.c
OUTDIR  := ../bin
BIN     := $(OUTDIR)/swallow-embed

.PHONY: all run clean

all: $(BIN)

$(BIN): $(SRC) | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

$(OUTDIR):
	mkdir -p $(OUTDIR)

run: $(BIN)
	./$(BIN) xterm

clean:
	rm -f $(BIN)
