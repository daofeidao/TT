#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

/*
 * ttFork: isolates where process creation dies on this device.
 * Runs the same loop twice — once with plain fork+_exit, once with
 * fork+exec — and prints the exact iteration that first fails.
 * A failure at iteration 1 means the mechanism itself is blocked;
 * a failure at iteration N means there is a fork budget of N-1.
 */
static const char *programPath = NULL;

static int reap(pid_t pid) {
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -2;
}

static int attempt(int useExec, int index) {
    pid_t pid = fork();
    if (pid < 0) {
        printf("  iter %2d: FORK() failed errno=%d (%s)\n", index, errno, strerror(errno));
        return -1;
    }
    if (pid == 0) {
        if (useExec) {
            execl(programPath, "ttprobe", (char *)NULL);
            _exit(126);
        }
        _exit(0);
    }
    return reap(pid);
}

static int failed(int rc) {
    return rc < 0 || rc >= 128;
}

int main(int argc, char **argv) {
    programPath = (argc > 1) ? argv[1] : "/bin/echo";
    int iterations = (argc > 2) ? atoi(argv[2]) : 8;
    if (iterations < 1 || iterations > 64) {
        iterations = 8;
    }

    printf("TT_FORK_BEGIN prog=%s n=%d\n", programPath, iterations);

    printf("-- pure fork+_exit --\n");
    int pureFailAt = 0;
    for (int i = 1; i <= iterations; i++) {
        int rc = attempt(0, i);
        printf("  iter %2d: rc=%d%s\n", i, rc, failed(rc) ? "  <== DIED" : "");
        if (failed(rc)) { pureFailAt = i; break; }
    }
    if (pureFailAt == 0) {
        printf("  result: all %d plain forks succeeded\n", iterations);
    } else {
        printf("  result: plain fork broke at iteration %d\n", pureFailAt);
    }

    printf("-- fork+exec --\n");
    int execFailAt = 0;
    for (int i = 1; i <= iterations; i++) {
        int rc = attempt(1, i);
        printf("  iter %2d: rc=%d%s\n", i, rc, failed(rc) ? "  <== DIED" : "");
        if (failed(rc)) { execFailAt = i; break; }
    }
    if (execFailAt == 0) {
        printf("  result: all %d fork+exec succeeded\n", iterations);
    } else {
        printf("  result: fork+exec broke at iteration %d\n", execFailAt);
    }

    printf("TT_FORK_SUMMARY plain=%s exec=%s\n",
           pureFailAt == 0 ? "ALL_OK" : "BROKEN",
           execFailAt == 0 ? "ALL_OK" : "BROKEN");
    printf("TT_FORK_END\n");
    return 0;
}