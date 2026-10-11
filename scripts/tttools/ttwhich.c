/* ttbin/which: report which file would be run for each command name.
 *
 * 用法: which [-a] 命令...
 *
 * -a 把 PATH 里所有命中的都列出来（不加就只报第一个，命中即停）。
 * 名字里带斜杠就直接查它本身，不走 PATH。
 * 有任何一个没找到，退出码就是 1——这样 `which foo && echo 有` 才有意义。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#define BUFSZ 4096

static int executable(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    if (!S_ISREG(st.st_mode)) return 0;   /* 目录不算 */
    return access(path, X_OK) == 0;
}

int main(int argc, char **argv) {
    int all = 0;
    int i = 1;
    int status = 0;
    const char *pathEnv = getenv("PATH");
    char work[BUFSZ];
    char buf[BUFSZ];

    if (pathEnv && *pathEnv) {
        snprintf(work, sizeof work, "%s", pathEnv);
    } else {
        snprintf(work, sizeof work, "/usr/bin:/bin:/usr/sbin:/sbin");
    }

    if (i < argc && strcmp(argv[i], "-a") == 0) {
        all = 1;
        i++;
    }
    if (i >= argc) {
        fprintf(stderr, "用法: which [-a] 命令...\n");
        return 1;
    }

    for (; i < argc; i++) {
        const char *name = argv[i];
        int found = 0;

        if (strchr(name, '/') != NULL) {
            if (executable(name)) {
                printf("%s\n", name);
                found = 1;
            }
        } else {
            /* **每个命令都要重新拷贝一份 PATH。**
             * strtok_r 会把分隔符就地改成 NUL，直接复用同一块缓冲区的话，
             * 第二个命令起就只会搜到第一个目录了——这是刚写出来时踩的坑。 */
            char each[BUFSZ];
            char *cursor;
            char *dir;

            snprintf(each, sizeof each, "%s", work);
            cursor = each;
            dir = strtok_r(cursor, ":", &cursor);
            for (; dir != NULL; dir = strtok_r(NULL, ":", &cursor)) {
                /* PATH 里的空项在 POSIX 里表示当前目录 */
                const char *prefix = (dir[0] == '\0') ? "." : dir;
                snprintf(buf, sizeof buf, "%s/%s", prefix, name);
                if (executable(buf)) {
                    printf("%s\n", buf);
                    found = 1;
                    if (!all) break;
                }
            }
        }

        if (!found) status = 1;           /* 没找到不打印任何东西 */
    }
    return status;
}