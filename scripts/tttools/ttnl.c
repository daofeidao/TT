#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/* 选项存全局，emit 就不用带一长串参数 */
static const char *opt_body = "t";    /* 有内容的行是否编号 */
static const char *opt_blank = "t";   /* 空行是否编号 */
static const char *opt_sep = "\t";
static int opt_width = 6;
static long opt_start = 1;

static void emit(FILE *in) {
    long n = opt_start;
    char *line;
    while ((line = read_line(in)) != NULL) {
        int empty = (line[0] == '\0');
        int show;
        if (empty) show = (strcmp(opt_blank, "n") != 0);
        else       show = (strcmp(opt_body, "n") != 0);
        if (show) {
            char num[32];
            snprintf(num, sizeof num, "%*ld", opt_width, n);
            printf("%s%s%s\n", num, opt_sep, line);
            n++;
        } else {
            printf("%s\n", line);
        }
        free(line);
    }
}

/* ttbin/nl: number lines.
 * 只做最常用的形态：-b 编号范围，-s 分隔符，-v 起始号，-w 宽度。
 * usage: nl [-b a|t|n] [-v n] [-w N] [-s SEP] [file...]
 */
int main(int argc, char **argv) {
    int i = 1;

    while (i < argc && argv[i][0] == '-' && argv[i][1]) {
        const char *a = argv[i] + 1;
        if (strcmp(a, "ba") == 0) { opt_body = "a"; opt_blank = "n"; i++; continue; }
        if (strcmp(a, "bt") == 0) { opt_body = "t"; opt_blank = "t"; i++; continue; }
        if (strcmp(a, "bn") == 0) { opt_body = "n"; opt_blank = "n"; i++; continue; }
        if (a[0] == 'b' && a[1] && !a[2]) { opt_body = a + 1; i++; continue; }
        if (a[0] == 's' && a[1] && !a[2]) { opt_sep = a + 1; i++; continue; }
        if (a[0] == 'v' && a[1] && !a[2]) { opt_start = atol(a + 1); i++; continue; }
        if (a[0] == 'w' && a[1] && !a[2]) { opt_width = atoi(a + 1); i++; continue; }
        /* 分离写法：-b a / -s : / -v 0 / -w 4 */
        if (a[0] == 'b' && !a[1] && i + 1 < argc) { opt_body = argv[i + 1]; i += 2; continue; }
        if (a[0] == 's' && !a[1] && i + 1 < argc) { opt_sep = argv[i + 1]; i += 2; continue; }
        if (a[0] == 'v' && !a[1] && i + 1 < argc) { opt_start = atol(argv[i + 1]); i += 2; continue; }
        if (a[0] == 'w' && !a[1] && i + 1 < argc) { opt_width = atoi(argv[i + 1]); i += 2; continue; }
        fprintf(stderr, "nl: 不认识的选项 %s\n", argv[i]);
        return 1;
    }

    if (opt_width < 1) opt_width = 1;

    if (i >= argc) {
        emit(stdin);
    } else {
        for (; i < argc; i++) {
            FILE *in = fopen(argv[i], "r");
            if (!in) {
                fprintf(stderr, "nl: %s: 打不开\n", argv[i]);
                return 1;
            }
            emit(in);
            fclose(in);
        }
    }
    return 0;
}
