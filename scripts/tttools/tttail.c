#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* ttbin/tail: print the last N lines (default 10). */
int main(int argc, char **argv) {
    long count = 10;
    const char **files = calloc((size_t)(argc > 1 ? argc : 1), sizeof(char *));
    int fileCount = 0;

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            if (argv[i][1] == 'n' && argv[i][2] != '\0') {
                count = strtol(argv[i] + 2, NULL, 10);
            } else if (argv[i][1] >= '0' && argv[i][1] <= '9') {
                count = strtol(argv[i] + 1, NULL, 10);
            } else {
                fprintf(stderr, "tail: unsupported option %s\n", argv[i]);
                free(files);
                return 1;
            }
        } else {
            files[fileCount++] = argv[i];
        }
    }
    if (fileCount == 0) files[fileCount++] = "-";

    for (int index = 0; index < fileCount; index++) {
        FILE *input = stdin;
        int closeIt = 0;
        if (strcmp(files[index], "-") != 0) {
            input = fopen(files[index], "r");
            if (!input) {
                fprintf(stderr, "tail: %s: %s\n", files[index], strerror(errno));
                free(files);
                return 1;
            }
            closeIt = 1;
        }
        // ring buffer of the last `count` lines
        char **buffer = calloc((size_t)(count > 0 ? count : 1), sizeof(char *));
        long stored = 0;
        long next = 0;
        char line[8192];
        while (fgets(line, sizeof(line), input)) {
            char *copy = strdup(line);
            if (!copy) break;
            if (stored < count) {
                buffer[stored++] = copy;
            } else {
                free(buffer[next]);
                buffer[next] = copy;
            }
            next = (next + 1) % count;
        }
        long start = (stored == count) ? next : 0;
        for (long i = 0; i < stored; i++) {
            char *item = buffer[(start + i) % count];
            if (item) { fputs(item, stdout); free(item); }
        }
        free(buffer);
        if (closeIt) fclose(input);
    }
    free(files);
    return 0;
}