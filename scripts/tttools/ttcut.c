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
    /* 只读 stdin 时只跑一遍，否则 for(;;) 会永远读同一条流 */
    int totalPasses = (fileCount == 0) ? 1 : fileCount;
    for (int pass = 0; pass < totalPasses; pass++) {
        FILE *input = stdin;
        int closeIt = 0;
        if (fileCount > 0 && strcmp(files[pass], "-") != 0) {
            input = fopen(files[pass], "r");
            if (!input) {
                fprintf(stderr, "cut: %s: cannot open\n", files[pass]);
                rc = 1;
                continue;
            }
            closeIt = 1;
        }
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
            } else {
                /* 先切出字段边界，再按 -f 给出的顺序输出（真实 cut 也是按列表顺序） */
                static size_t spans[512][2];
                int fieldCount = 0;
                if (haveDelim) {
                    size_t start = 0;
                    for (size_t i = 0; i <= len && fieldCount < 512; i++) {
                        if (i == len || buffer[i] == delim) {
                            spans[fieldCount][0] = start;
                            spans[fieldCount][1] = i - start;
                            fieldCount++;
                            start = i + 1;
                        }
                    }
                } else {
                    /* 默认分隔符是空白串，连续空白算一个字段 */
                    size_t i = 0;
                    while (i < len && fieldCount < 512) {
                        while (i < len && (buffer[i] == ' ' || buffer[i] == '\t')) i++;
                        if (i >= len) break;
                        size_t start = i;
                        while (i < len && buffer[i] != ' ' && buffer[i] != '\t') i++;
                        spans[fieldCount][0] = start;
                        spans[fieldCount][1] = i - start;
                        fieldCount++;
                    }
                }
                int printed = 0;
                for (int w = 0; w < wantedCount; w++) {
                    int index = wanted[w] - 1;
                    if (index < 0 || index >= fieldCount) continue;
                    if (printed) putchar(haveDelim ? delim : ' ');
                    fwrite(buffer + spans[index][0], 1, spans[index][1], stdout);
                    printed = 1;
                }
            }
            if (hadNewline) putchar('\n');
        }
        if (closeIt) fclose(input);
    }
    return rc;
}