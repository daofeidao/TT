#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ttbin/sort: sort lines. Supports -n (numeric), -r (reverse), -u (unique). */

typedef struct {
    char **items;
    size_t count;
    size_t capacity;
    int numeric;
} LineSet;

static int pushLine(LineSet *set, const char *line) {
    if (set->count == set->capacity) {
        size_t next = set->capacity ? set->capacity * 2 : 256;
        char **grown = realloc(set->items, next * sizeof(char *));
        if (!grown) return 1;
        set->items = grown;
        set->capacity = next;
    }
    set->items[set->count++] = strdup(line);
    return 0;
}

static int compareLines(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static int compareNumeric(const void *a, const void *b) {
    const char *x = *(const char *const *)a;
    const char *y = *(const char *const *)b;
    char *endX = NULL, *endY = NULL;
    double nx = strtod(x, &endX);
    double ny = strtod(y, &endY);
    if (nx != ny) return nx < ny ? -1 : 1;
    return strcmp(x, y);
}

int main(int argc, char **argv) {
    int numeric = 0, reverse = 0, unique = 0;
    const char *files[64];
    int fileCount = 0;

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            for (const char *f = argv[i] + 1; *f; f++) {
                if (*f == 'n') numeric = 1;
                else if (*f == 'r') reverse = 1;
                else if (*f == 'u') unique = 1;
                else {
                    fprintf(stderr, "sort: unsupported option -%c (supports -n -r -u)\n", *f);
                    return 1;
                }
            }
        } else if (fileCount < 64) {
            files[fileCount++] = argv[i];
        }
    }

    LineSet set = { NULL, 0, 0, numeric };
    char buffer[65536];
    int rc = 0;

    /* 与真实 sort 一致：给了文件就不再读 stdin，避免管道外调用挂住。
     * 只读 stdin 时必须只跑一遍，否则 for(;;) 会永远读同一条流。 */
    int totalPasses = (fileCount == 0) ? 1 : fileCount;
    for (int pass = 0; pass < totalPasses; pass++) {
        FILE *input = stdin;
        int closeIt = 0;
        if (fileCount > 0 && strcmp(files[pass], "-") != 0) {
            input = fopen(files[pass], "r");
            if (!input) {
                fprintf(stderr, "sort: %s: cannot open\n", files[pass]);
                rc = 1;
                continue;
            }
            closeIt = 1;
        }
        while (fgets(buffer, sizeof buffer, input)) {
            size_t len = strlen(buffer);
            while (len > 0 && (buffer[len - 1] == '\n' || buffer[len - 1] == '\r')) {
                buffer[--len] = '\0';
            }
            if (pushLine(&set, buffer)) { rc = 1; break; }
        }
        if (closeIt) fclose(input);
    }
    if (rc) {
        for (size_t i = 0; i < set.count; i++) free(set.items[i]);
        free(set.items);
        return 1;
    }

    if (set.count > 1) {
        qsort(set.items, set.count, sizeof(char *), numeric ? compareNumeric : compareLines);
    }

    for (size_t i = 0; i < set.count; i++) {
        size_t index = reverse ? set.count - 1 - i : i;
        if (unique && index > 0 && strcmp(set.items[index], set.items[index - 1]) == 0) continue;
        printf("%s\n", set.items[index]);
    }

    for (size_t i = 0; i < set.count; i++) free(set.items[i]);
    free(set.items);
    return 0;
}