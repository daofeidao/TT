/* ttbin/basename: strip directory and suffix from a path (POSIX).
 *
 * 用法: basename 路径 [后缀]
 *      basename 路径 路径 ...      每个一行
 *
 * POSIX 的边角规定都按标准来：
 *   basename /            → /
 *   basename ""            → .
 *   basename a/b/          → b        （结尾斜杠先去掉）
 *   basename a/b.tar .tar  → b
 *   basename .tar .tar     → .tar     （整个串就是后缀时不剥）
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUFSZ 4096

static const char *base(const char *path, const char *suffix, char *out) {
    size_t len = strlen(path);
    size_t start = 0;
    size_t i;
    size_t n;

    /* 先去掉结尾的斜杠，但至少留一个字符 */
    while (len > 1 && path[len - 1] == '/') len--;

    /* 全是斜杠（也就是 "/"）*/
    if (len == 1 && path[0] == '/') {
        snprintf(out, BUFSZ, "/");
        return out;
    }

    /* 最后一个斜杠之后才是 basename */
    for (i = 0; i < len; i++) {
        if (path[i] == '/') start = i + 1;
    }
    n = len - start;
    if (n == 0) {
        snprintf(out, BUFSZ, ".");
        return out;
    }

    /* 剥后缀：整个串就是后缀时不动它（POSIX 明确要求） */
    if (suffix && *suffix) {
        size_t sl = strlen(suffix);
        if (n > sl && memcmp(path + start + n - sl, suffix, sl) == 0) {
            n -= sl;
        }
    }
    if (n == 0) {
        snprintf(out, BUFSZ, ".");
        return out;
    }
    if (n >= BUFSZ) n = BUFSZ - 1;
    memcpy(out, path + start, n);
    out[n] = '\0';
    return out;
}

int main(int argc, char **argv) {
    char buf[BUFSZ];
    int i;

    if (argc < 2) {
        fprintf(stderr, "用法: basename 路径 [后缀]\n");
        return 1;
    }

    if (argc == 3) {
        printf("%s\n", base(argv[1], argv[2], buf));
        return 0;
    }

    for (i = 1; i < argc; i++) {
        printf("%s\n", base(argv[i], NULL, buf));
    }
    return 0;
}