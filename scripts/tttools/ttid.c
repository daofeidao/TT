/* ttbin/id: print user and group identity.
 *
 * 用法: id [-u|-g|-G|-n]
 *
 * 默认输出格式跟 POSIX 一样：uid=501(mobile) gid=501(mobile) groups=501(mobile)
 *
 * 系统里**没有** id 这个程序（权限检测报告实测：/usr/bin、/bin、/sbin、/usr/sbin 都没有），
 * 所以这个是自己编的。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <grp.h>

static const char *userName(uid_t uid) {
    struct passwd *pw = getpwuid(uid);
    return (pw != NULL && pw->pw_name != NULL) ? pw->pw_name : "unknown";
}

static const char *groupName(gid_t gid) {
    struct group *gr = getgrgid(gid);
    return (gr != NULL && gr->gr_name != NULL) ? gr->gr_name : "unknown";
}

/* 读全部附加组 id，读不到就退化成只有主组 */
static int collectGroups(gid_t *list, int max) {
    int n = getgroups(0, NULL);
    if (n <= 0) return 0;
    if (n > max) n = max;
    if (getgroups(n, list) < 0) return 0;
    return n;
}

int main(int argc, char **argv) {
    /* 0 全量 / 1 uid / 2 gid / 3 所有组号 / 4 用户名 */
    int mode = 0;
    uid_t uid;
    gid_t gid;
    gid_t groups[64];
    int groupCount;

    if (argc > 1) {
        if (strcmp(argv[1], "-u") == 0) mode = 1;
        else if (strcmp(argv[1], "-g") == 0) mode = 2;
        else if (strcmp(argv[1], "-G") == 0) mode = 3;
        else if (strcmp(argv[1], "-n") == 0) mode = 4;
        else {
            fprintf(stderr, "id: 未知选项 %s\n", argv[1]);
            fprintf(stderr, "用法: id [-u|-g|-G|-n]\n");
            return 1;
        }
    }

    uid = getuid();
    gid = getgid();

    switch (mode) {
    case 1:
        printf("%u\n", (unsigned)uid);
        return 0;
    case 2:
        printf("%u\n", (unsigned)gid);
        return 0;
    case 3:
        groupCount = collectGroups(groups, 64);
        if (groupCount == 0) {
            printf("%u\n", (unsigned)gid);
            return 0;
        }
        {
            int i;
            for (i = 0; i < groupCount; i++) {
                printf("%s%u", (i > 0) ? " " : "", (unsigned)groups[i]);
            }
            printf("\n");
        }
        return 0;
    case 4:
        printf("%s\n", userName(uid));
        return 0;
    default:
        break;
    }

    printf("uid=%u(%s) gid=%u(%s)",
           (unsigned)uid, userName(uid),
           (unsigned)gid, groupName(gid));

    groupCount = collectGroups(groups, 64);
    if (groupCount > 0) {
        int i;
        printf(" groups=");
        for (i = 0; i < groupCount; i++) {
            printf("%s%u(%s)",
                   (i > 0) ? "," : "",
                   (unsigned)groups[i], groupName(groups[i]));
        }
    }
    printf("\n");
    return 0;
}