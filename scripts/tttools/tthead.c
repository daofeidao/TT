#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* ttbin/head: print the first N lines (default 10). */
int main(int argc, char **argv) {
    long count = 10;
    int sawCount = 0;
    const char **files = calloc((size_t)(argc > 1 ? argc : 1), sizeof(char *));
    int fileCount = 0;

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            if (argv[i][1] == 'n' && argv[i][2] != '\0') {
                count = strtol(argv[i] + 2, NULL, 10);
                sawCount = 1;
            } else if (argv[i][1] >= '0' && argv[i][1] <= '9') {
                count = strtol(argv[i] + 1, NULL, 10);
                sawCount = 1;
            } else {
                fprintf(stderr, "head: unsupported option %s\n", argv[i]);
                free(files);
                return 1;
            }
        } else {
            files[fileCount++] = argv[i];
        }
    }
    (void)sawCount;
    if (fileCount == 0) files[fileCount++] = "-";

    for (int index = 0; index < fileCount; index++) {
        FILE *input = stdin;
        int closeIt = 0;
        if (strcmp(files[index], "-") != 0) {
            input = fopen(files[index], "r");
            if (!input) {
                fprintf(stderr, "head: %s: %s\n", files[index], strerror(errno));
                free(files);
                return 1;
            }
            closeIt = 1;
        }
        char line[8192];
        long printed = 0;
        while (printed < count && fgets(line, sizeof(line), input)) {
            fputs(line, stdout);
            printed++;
        }
        if (closeIt) fclose(input);
    }
    free(files);
    return 0;
}