#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ttbin/cut: select fields or characters.
 * 用法：cut [-d DELIM] (-f LIST | -c LIST) [FILE...]
 * 附着写法（-f1、-d:）与分离写法（-f 1、-d :）都支持。
 * 支持列表：1 / 1,3 / 2-5 / 1-3,7
 */

static int parseList(const char *spec, int *out, int max) {
    int n = 0;
    const char *p = spec;
    while (*p && n < max) {
        while (*p == ',' || *p == ' ') p++;
        if (*p < '0' || *p > '9') break;
        int lo = 0;
        while (*p >= '0' && *p <= '9') { lo = lo * 10 + (*p - '0'); p++; }
        int hi = lo;
        if (*p == '-') {
            p++;
            hi = 0;
            if (*p >= '0' && *p <= '9') {
                while (*p >= '0' && *p <= '9') { hi = hi * 10 + (*p - '0'); p++; }
            } else {
                hi = lo;            /* "3-" 表示从 3 到行尾，用大哨兵表示 */
            }
        }
        if (hi == 0) hi = lo;
        for (int i = lo; i <= hi && n < max; i++) out[n++] = i;
    }
    return n;
}

/* 打开下一个输入源；返回 NULL 表示已到末尾 */
static FILE *nextInput(const char *files, int fileCount, int pass, const char *name) {
    if (fileCount == 0) return stdin;
    if (pass >= fileCount) return NULL;
    if (strcmp(files[pass], "-") == 0) return stdin;
    FILE *f = fopen(files[pass], "r");
    if (!f) fprintf(stderr, "%s: %s: cannot open\n", name, files[pass]);
    return f;
}

int main(int argc, char **argv) {
    char delim = '\t';
    int haveDelim = 0;
    const char *fieldSpec = NULL;
    const char *charSpec = NULL;
    const char *files[64];
    int fileCount = 0;
    int wantHelp = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (a[0] != '-' || a[1] == '\0') {
            if (fileCount < 64) files[fileCount++] = a;
            continue;
        }
        if (strcmp(a, "--help") == 0) { wantHelp = 1; break; }
        /* 只扫描本 token 内属于本选项的字符，遇到非本选项字母即认为是下一个选项 */
        for (const char *f = a + 1; *f; f++) {
            if (*f == 'd') {
                if (f[1]) {
                    /* -d: 或 -d\t 等附着分隔符 */
                    const char *src = f + 1;
                    if (src[0] == '\\' && src[1]) src++;
                    delim = *src;
                    haveDelim = 1;
                    break;           /* 剩下的字符不是选项了 */
                }
                if (i + 1 < argc) {
                    i++;
                    const char *v = argv[i];
                    delim = (v[0] == '\\' && v[1]) ? v[1] : v[0];
                    haveDelim = 1;
                } else {
                    fprintf(stderr, "cut: -d needs a delimiter\n");
                    return 1;
                }
                break;
            }
            if (*f == 'f' || *f == 'c') {
                int isField = (*f == 'f');
                const char *v;
                if (f[1]) {
                    v = f + 1;      /* -f1 */
                } else if (i + 1 < argc) {
                    v = argv[++i];  /* -f 1 */
                } else {
                    fprintf(stderr, "cut: -%c needs a list\n", *f);
                    return 1;
                }
                if (isField) fieldSpec = v; else charSpec = v;
                break;
            }
            fprintf(stderr, "cut: unsupported option -%c (supports -d -f -c)\n", *f);
            return 1;
        }
    }

    if (wantHelp) {
        printf("usage: cut [-d DELIM] (-f LIST | -c LIST) [FILE...]\n");
        return 0;
    }
    if (!fieldSpec && !charSpec) {
        fprintf(stderr, "cut: usage: cut [-d DELIM] (-f LIST | -c LIST) [FILE...]\n");
        return 1;
    }

    int wanted[512];
    int wantedCount = parseList(fieldSpec ? fieldSpec : charSpec, wanted, 512);
    if (wantedCount == 0) {
        fprintf(stderr, "cut: empty selection\n");
        return 1;
    }

    char buffer[65536];
    int rc = 0;
    for (int pass = 0; ; pass++) {
        FILE *input = nextInput(files, fileCount, pass, "cut");
        if (fileCount > 0 && pass >= fileCount) break;
        if (!input) { rc = 1; continue; }

        while (fgets(buffer, sizeof buffer, input)) {
            size_t len = strlen(buffer);
            int hadNewline = 0;
            while (len > 0 && (buffer[len - 1] == '\n' || buffer[len - 1] == '\r')) {
                buffer[--len] = '\0';
                hadNewline = 1;
            }
            if (charSpec) {
                for (int i = 0; i < wantedCount; i++) {
                    if (wanted[i] >= 1 && wanted[i] <= (int)len) putchar(buffer[wanted[i] - 1]);
                }
            } else if (haveDelim) {
                int field = 1;
                size_t start = 0;
                for (size_t i = 0; i <= len; i++) {
                    if (i == len || buffer[i] == delim) {
                        for (int w = 0; w < wantedCount; w++) {
                            if (wanted[w] == field) {
                                fwrite(buffer + start, 1, i - start, stdout);
                            }
                        }
                        field++;
                        start = i + 1;
                    }
                }
            } else {
                /* 默认分隔符是空白串，多个连续空白算一个字段 */
                size_t i = 0;
                int field = 0;
                while (i < len) {
                    while (i < len && (buffer[i] == ' ' || buffer[i] == '\t')) i++;
                    if (i >= len) break;
                    size_t start = i;
                    while (i < len && buffer[i] != ' ' && buffer[i] != '\t') i++;
                    field++;
                    for (int w = 0; w < wantedCount; w++) {
                        if (wanted[w] == field) {
                            fwrite(buffer + start, 1, i - start, stdout);
                            break;
                        }
                    }
                }
            }
            if (hadNewline) putchar('\n');
        }
        if (input != stdin) fclose(input);
    }
    return rc;
}