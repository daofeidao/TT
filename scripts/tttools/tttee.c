#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* 逐行读入，缓冲区自动增长。返回 NULL 表示到文件尾。
 * 不用 getline：iOS 上虽然有，但固定实现更省心。 */
static char *read_line(FILE *f) {
    size_t cap = 256, len = 0;
    char *buf = (char *)malloc(cap);
    int c;
    if (!buf) return NULL;
    while ((c = fgetc(f)) != EOF) {
        if (len + 2 > cap) {
            size_t ncap = cap * 2;
            char *nb = (char *)realloc(buf, ncap);
            if (!nb) { free(buf); return NULL; }
            buf = nb;
            cap = ncap;
        }
        if (c == '\n') break;
        buf[len++] = (char)c;
    }
    if (len == 0 && c == EOF) { free(buf); return NULL; }
    buf[len] = '\0';
    return buf;
}

/* ttbin/tee: copy stdin to files and to stdout.
 * usage: tee [-a] file...
 */
int main(int argc, char **argv) {
    int append = 0;
    int first = 1;
    FILE **outs;
    int nout = 0;
    char *line;

    while (first < argc && argv[first][0] == '-' && argv[first][1]) {
        const char *a = argv[first] + 1;
        int bad = 0;
        for (const char *q = a; *q; q++) {
            if (*q == 'a') append = 1;
            else bad = 1;
        }
        if (bad) break;
        first++;
    }

    if (first >= argc) {
        /* 没有文件：只是把 stdin 原样倒到 stdout */
        while ((line = read_line(stdin)) != NULL) {
            fputs(line, stdout);
            fputc('\n', stdout);
            free(line);
        }
        return 0;
    }

    outs = (FILE **)calloc((size_t)(argc - first) + 1, sizeof(FILE *));
    if (!outs) return 1;

    for (int i = first; i < argc; i++) {
        FILE *f = fopen(argv[i], append ? "a" : "w");
        if (!f) {
            fprintf(stderr, "tee: %s: %s\n", argv[i], strerror(errno));
            for (int k = 0; k < nout; k++) fclose(outs[k]);
            free(outs);
            return 1;
        }
        outs[nout++] = f;
    }

    while ((line = read_line(stdin)) != NULL) {
        fputs(line, stdout);
        fputc('\n', stdout);
        for (int i = 0; i < nout; i++) {
            fputs(line, outs[i]);
            fputc('\n', outs[i]);
        }
        free(line);
    }

    for (int i = 0; i < nout; i++) fclose(outs[i]);
    free(outs);
    return 0;
}
