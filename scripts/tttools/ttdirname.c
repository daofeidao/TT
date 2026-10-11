/* ttbin/dirname: strip the last component from a path (POSIX).
 *
 * 用法: dirname 路径...
 *
 * POSIX 的边角规定：
 *   dirname /       → /
 *   dirname ""      → .
 *   dirname a       → .
 *   dirname a/b     → a
 *   dirname a/b/    → a          （结尾斜杠先去掉）
 *   dirname /usr//  → /usr       （中间的重复斜杠也收掉）
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUFSZ 4096

static const char *dir(const char *path, char *out) {
    size_t len = strlen(path);
    size_t i;

    while (len > 1 && path[len - 1] == '/') len--;

    if (len == 0) {                       /* 空串 */
        snprintf(out, BUFSZ, ".");
        return out;
    }
    if (len == 1 && path[0] == '/') {     /* 根目录 */
        snprintf(out, BUFSZ, "/");
        return out;
    }

    /* i 停在最后一个斜杠的后面 */
    i = len;
    while (i > 0 && path[i - 1] != '/') i--;

    /* 把末尾的重复斜杠也收掉：/usr// → /usr */
    while (i > 1 && path[i - 1] == '/') i--;

    if (i == 0) {                         /* 没有斜杠，相对路径的单段 */
        snprintf(out, BUFSZ, ".");
        return out;
    }
    if (i >= BUFSZ) i = BUFSZ - 1;
    memcpy(out, path, i);
    out[i] = '\0';
    return out;
}

int main(int argc, char **argv) {
    char buf[BUFSZ];
    int i;

    if (argc < 2) {
        fprintf(stderr, "用法: dirname 路径...\n");
        return 1;
    }
    for (i = 1; i < argc; i++) {
        printf("%s\n", dir(argv[i], buf));
    }
    return 0;
}