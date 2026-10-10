#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>
#include <fnmatch.h>

/* ttbin/find: walk a path and match names.
 * 用法：find [PATH...] [-name PATTERN | -iname PATTERN] [-type f|d]
 */

static const char *namePattern = NULL;
static char wantedType = 0;          /* 'f' 普通文件 / 'd' 目录，0 不限 */
static int caseInsensitive = 0;

static int matches(const char *name, int isDir) {
    if (wantedType) {
        if (wantedType == 'd' && !isDir) return 0;
        if (wantedType == 'f' && isDir) return 0;
    }
    if (!namePattern) return 1;
    int flags = caseInsensitive ? FNM_CASEFOLD : 0;
    return fnmatch(namePattern, name, flags) == 0;
}

static void walk(const char *path, int depth) {
    if (depth > 24) return;
    struct stat st;
    if (lstat(path, &st) != 0) return;
    if (!S_ISDIR(st.st_mode)) return;

    DIR *dir = opendir(path);
    if (!dir) return;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        char child[4096];
        snprintf(child, sizeof child, "%s/%s", path, entry->d_name);
        struct stat cst;
        int childIsDir = (lstat(child, &cst) == 0) && S_ISDIR(cst.st_mode);
        if (matches(entry->d_name, childIsDir)) {
            printf("%s\n", child);
        }
        if (childIsDir) walk(child, depth + 1);
    }
    closedir(dir);
}

int main(int argc, char **argv) {
    const char *roots[16];
    int rootCount = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-name") == 0) {
            if (i + 1 < argc) { namePattern = argv[++i]; }
            else { fprintf(stderr, "find: -name needs a pattern\n"); return 1; }
        } else if (strcmp(argv[i], "-iname") == 0) {
            if (i + 1 < argc) { namePattern = argv[++i]; caseInsensitive = 1; }
            else { fprintf(stderr, "find: -iname needs a pattern\n"); return 1; }
        } else if (strcmp(argv[i], "-type") == 0) {
            if (i + 1 < argc) {
                const char *t = argv[++i];
                if (strcmp(t, "f") == 0) wantedType = 'f';
                else if (strcmp(t, "d") == 0) wantedType = 'd';
                else { fprintf(stderr, "find: -type only supports f or d\n"); return 1; }
            } else {
                fprintf(stderr, "find: -type needs f or d\n");
                return 1;
            }
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "find: unsupported option %s (supports -name -iname -type)\n", argv[i]);
            return 1;
        } else if (rootCount < 16) {
            roots[rootCount++] = argv[i];
        }
    }
    if (rootCount == 0) roots[rootCount++] = ".";

    int rc = 0;
    for (int i = 0; i < rootCount; i++) {
        struct stat st;
        if (lstat(roots[i], &st) != 0) {
            fprintf(stderr, "find: %s: %s\n", roots[i], strerror(errno));
            rc = 1;
            continue;
        }
        int isDir = S_ISDIR(st.st_mode);
        const char *leaf = strrchr(roots[i], '/');
        leaf = leaf ? leaf + 1 : roots[i];
        if (matches(leaf, isDir)) printf("%s\n", roots[i]);
        if (isDir) walk(roots[i], 0);
    }
    return rc;
}