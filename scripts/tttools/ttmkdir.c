#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

/* ttbin/mkdir: create directories, supports -p. */
int main(int argc, char **argv) {
    int parents = 0;
    int first = 1;
    if (argc < 2) {
        fprintf(stderr, "mkdir: missing operand\n");
        return 1;
    }
    if (strcmp(argv[1], "-p") == 0) {
        parents = 1;
        first = 2;
    }
    int rc = 0;
    for (int i = first; i < argc; i++) {
        if (mkdir(argv[i], 0755) != 0 && !(parents && errno == EEXIST)) {
            fprintf(stderr, "mkdir: %s: %s\n", argv[i], strerror(errno));
            rc = 1;
        }
    }
    return rc;
}