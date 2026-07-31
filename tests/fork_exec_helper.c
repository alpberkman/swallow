/*
 * Simulates a launcher that forks the real application and exits
 * immediately (e.g. a shell wrapper doing `real_binary &`, or classic
 * double-fork daemonizing). The process swallow directly launches is gone
 * before any window exists; the window later shows up owned by a process
 * reparented to init. Used to test that swallow still correctly picks up
 * the window despite that indirection.
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <command> [args...]\n", argv[0]);
        return 2;
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (pid > 0)
        _exit(0); /* launcher exits right away */

    usleep(200000); /* let the parent exit first */
    execvp(argv[1], &argv[1]);
    perror("execvp");
    _exit(127);
}
