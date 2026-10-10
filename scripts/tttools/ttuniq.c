#include <stdio.h>
#include <string.h>

/* ttbin/uniq: drop adjacent duplicate lines. Supports -c (show counts). */

#define LINE_MAX_LEN 65536

static void emit(const char *line, long count, int showCount) {
    if (showCount) printf("%7ld %s\n", count, line);
    else printf("%s\n", line);
}

int main(int argc, char **argv) {
    int showCount = 0;
    const char *files[64];
    int fileCount = 0;

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            for (const char *f = argv[i] + 1; *f; f++) {
                if (*f == 'c') showCount = 1;
                else {
                    fprintf(stderr, "uniq: unsupported option -%c (supports -c)\n", *f);
                    return 1;
                }
            }
        } else if (fileCount < 64) {
            files[fileCount++] = argv[i];
        }
    }

    static char previous[LINE_MAX_LEN];
    static char current[LINE_MAX_LEN];
    int havePrevious = 0;
    long repeats = 0;          /* 上一行已连续出现的次数（含第一次即 0） */
    int rc = 0;

    /* 只读 stdin 时只跑一遍，否则 for(;;) 会永远读同一条流 */
    int totalPasses = (fileCount == 0) ? 1 : fileCount;
    for (int pass = 0; pass < totalPasses; pass++) {
        FILE *input = stdin;
        int closeIt = 0;
        if (fileCount > 0 && strcmp(files[pass], "-") != 0) {
            input = fopen(files[pass], "r");
            if (!input) {
                fprintf(stderr, "uniq: %s: cannot open\n", files[pass]);
                rc = 1;
                continue;
            }
            closeIt = 1;
        }
        while (fgets(current, sizeof current, input)) {
            size_t len = strlen(current);
            while (len > 0 && (current[len - 1] == '\n' || current[len - 1] == '\r')) {
                current[--len] = '\0';
            }
            if (havePrevious && strcmp(current, previous) == 0) {
                repeats++;
                continue;
            }
            if (havePrevious) {
                emit(previous, repeats + 1, showCount);
            }
            memcpy(previous, current, len + 1);
            havePrevious = 1;
            repeats = 0;
        }
        if (closeIt) fclose(input);
    }

    if (havePrevious) {
        emit(previous, repeats + 1, showCount);
    }
    return rc;
}