CC     ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11

BIN := fork_exec_helper

.PHONY: all clean

all: $(BIN)

$(BIN): fork_exec_helper.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(BIN)
