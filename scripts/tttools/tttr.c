#include <stdio.h>
#include <string.h>

/* ttbin/tr: translate or delete characters. */
static int expandSet(const char *set, char *out, int max) {
    int n = 0;
    for (const char *p = set; *p && n < max; p++) {
        if (p[1] == '-' && p[2] != '\0' && p[2] >= *p) {
            for (char c = *p; c <= p[2] && n < max; c++) out[n++] = c;
            p += 2;
        } else {
            out[n++] = *p;
        }
    }
    return n;
}

int main(int argc, char **argv) {
    int deleteMode = 0;
    const char *sets[2] = { NULL, NULL };
    int setCount = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-d") == 0) { deleteMode = 1; continue; }
        if (strcmp(argv[i], "--delete") == 0) { deleteMode = 1; continue; }
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            fprintf(stderr, "tr: unsupported option %s\n", argv[i]);
            return 1;
        }
        if (setCount < 2) sets[setCount++] = argv[i];
    }

    if (setCount == 0) {
        fprintf(stderr, "tr: usage: tr [-d] SET1 [SET2]\n");
        return 1;
    }
    if (!deleteMode && setCount < 2) {
        fprintf(stderr, "tr: SET2 required unless -d is used\n");
        return 1;
    }

    char from[512], to[512];
    int fromCount = expandSet(sets[0], from, sizeof from);
    int toCount = deleteMode ? 0 : expandSet(sets[1], to, sizeof to);
    if (!deleteMode && fromCount != toCount) {
        fprintf(stderr, "tr: SET1 and SET2 must be the same length\n");
        return 1;
    }

    int c;
    while ((c = getchar()) != EOF) {
        int index = -1;
        for (int i = 0; i < fromCount; i++) {
            if (from[i] == (char)c) { index = i; break; }
        }
        if (index < 0) {
            putchar(c);
        } else if (!deleteMode) {
            putchar(to[index]);
        }
    }
    return 0;
}