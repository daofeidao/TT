#include <stdio.h>
#include <string.h>
#include <errno.h>

/* ttbin/cat: print files to stdout. */
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "cat: missing file operand\n");
        return 1;
    }
    int rc = 0;
    char buf[8192];
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) {
            fprintf(stderr, "cat: %s: %s\n", argv[i], strerror(errno));
            rc = 1;
            continue;
        }
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
            fwrite(buf, 1, n, stdout);
        }
        fclose(f);
    }
    return rc;
}
