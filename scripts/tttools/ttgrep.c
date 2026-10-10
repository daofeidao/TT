#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* ttbin/grep: print lines containing PATTERN (substring match). */
static int scan(FILE *input, const char *pattern, const char *name, int invert) {
    char line[8192];
    int matches = 0;
    while (fgets(line, sizeof(line), input)) {
        size_t length = strlen(line);
        while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
            line[--length] = '\0';
        }
        int contains = strstr(line, pattern) != NULL;
        if (contains != invert) {
            printf("%s\n", line);
            matches++;
        }
    }
    (void)name;
    return matches;
}

int main(int argc, char **argv) {
    const char *pattern = NULL;
    const char **files = calloc((size_t)(argc > 1 ? argc : 1), sizeof(char *));
    int fileCount = 0;
    int invert = 0;

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0' && pattern == NULL) {
            for (const char *flag = argv[i] + 1; *flag; flag++) {
                if (*flag == 'v') invert = 1;
                else {
                    fprintf(stderr, "grep: unsupported option -%c\n", *flag);
                    free(files);
                    return 1;
                }
            }
        } else if (pattern == NULL) {
            pattern = argv[i];
        } else {
            files[fileCount++] = argv[i];
        }
    }

    if (!pattern) {
        fprintf(stderr, "grep: usage: grep PATTERN [FILE...]\n");
        free(files);
        return 2;
    }

    int total = 0;
    if (fileCount == 0) {
        total = scan(stdin, pattern, NULL, invert);
    } else {
        for (int i = 0; i < fileCount; i++) {
            FILE *input = fopen(files[i], "r");
            if (!input) {
                fprintf(stderr, "grep: %s: %s\n", files[i], strerror(errno));
                free(files);
                return 2;
            }
            int found = scan(input, pattern, files[i], invert);
            fclose(input);
            total += found;
        }
    }

    return total > 0 ? 0 : 1;
}