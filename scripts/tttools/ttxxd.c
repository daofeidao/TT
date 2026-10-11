/* ttbin/xxd: hex dump, and turn a dump back into bytes.
 *
 * 输出格式和 xxd 一致：8 位偏移、冒号、16 字节的十六进制（中间第 8 字节后多一个空格），
 * 然后两格空白，最后是右侧的 ASCII（不可打印字符打成 .）。
 *
 * 用法: xxd [-r] [file]
 * 不带文件时读 stdin。-r 是反向：读十六进制、还原成字节，遇到空行停止。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define COLS 16
#define GROUP 8

/* 返回 int（恒为 0）而不是 void：
 * main 里要写 `doReverse ? reverse(...) : hexdump(...)`，
 * 两边类型不一致编译不过。 */
static int hexdump(FILE *in, FILE *out) {
    unsigned char buf[COLS];
    size_t n;
    unsigned long offset = 0;

    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        size_t i;
        fprintf(out, "%08lx:", (unsigned long)offset);
        for (i = 0; i < COLS; i++) {
            fputc(' ', out);
            if (i == GROUP) fputc(' ', out);     /* 8 字节一组，中间空一格 */
            if (i < n) fprintf(out, "%02x", buf[i]);
            else fputs("  ", out);
        }
        fputs("  ", out);
        for (i = 0; i < n; i++) {
            int c = buf[i];
            fputc((c >= 32 && c < 127) ? c : '.', out);
        }
        fputc('\n', out);
        offset += (unsigned long)n;
    }
    return 0;
}

static int hexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* 反向：读十六进制还原成字节。
 *
 * 必须**逐行**处理，而且要认出 xxd 自己那种 `00000000:` 的偏移列——
 * 第一版写成逐字符扫，结果一碰到偏移列里的 ':' 就报「非法十六进制字符」，
 * 自己 dump 出来的东西自己也读不回去。
 *
 * 每行的解析规则（和真 xxd -r 对齐）：
 *   1. 开头 8 个十六进制 + 一个 ':'  → 是偏移列，跳过；
 *      否则当成纯十六进制行，从头开始。
 *   2. 往后解析十六进制和单空格；
 *   3. **连续两格空白** = 十六进制列结束，剩下的是 ASCII 列，不看。
 *   4. 遇到别的字符 → 报错。
 *   5. 整行只有空白 → 输入结束（和真 xxd 一个规矩）。
 */
static int reverse(FILE *in, FILE *out) {
    char line[4096];
    int hi = -1;

    while (fgets(line, sizeof line, in) != NULL) {
        char *p = line;
        int prevSpace = 0;
        int lead = 0;
        int onlySpace = 1;
        char *scan;

        for (scan = line; *scan; scan++) {
            if (*scan != ' ' && *scan != '\t' && *scan != '\r' && *scan != '\n') {
                onlySpace = 0;
                break;
            }
        }
        if (onlySpace) break;                  /* 空行 = 输入结束 */

        /* 偏移列：最多 8 个十六进制 */
        while (lead < 8 && hexDigit(p[lead]) >= 0) lead++;
        if (lead == 8) {
            p += lead;
            if (*p == ':') p++;
        } else {
            p = line;                          /* 不是偏移列，整行当十六进制 */
        }

        for (; *p; p++) {
            int v;
            if (*p == '\n' || *p == '\r') break;
            if (*p == ' ' || *p == '\t') {
                if (prevSpace) break;          /* 两格空白 → 进 ASCII 列了 */
                prevSpace = 1;
                continue;
            }
            v = hexDigit(*p);
            if (v < 0) {
                fprintf(stderr, "xxd: 非法十六进制字符 '%c'\n", *p);
                return 1;
            }
            prevSpace = 0;
            if (hi < 0) {
                hi = v;
            } else {
                fputc((hi << 4) | v, out);
                hi = -1;
            }
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    int doReverse = 0;
    int i = 1;
    const char *path = NULL;

    while (i < argc) {
        if (strcmp(argv[i], "-r") == 0) {
            doReverse = 1;
            i++;
            continue;
        }
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            fprintf(stdout, "用法: xxd [-r] [文件]\n");
            return 0;
        }
        path = argv[i];
        i++;
        break;
    }

    if (!path || strcmp(path, "-") == 0) {
        return doReverse ? reverse(stdin, stdout) : hexdump(stdin, stdout);
    }

    {
        FILE *in = fopen(path, "rb");
        int rc;
        if (!in) {
            fprintf(stderr, "xxd: %s: %s\n", path, strerror(errno));
            return 1;
        }
        rc = doReverse ? reverse(in, stdout) : hexdump(in, stdout);
        fclose(in);
        return rc;
    }
}