#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

/* ttbin/rm: remove files and directories. Supports -r (recursive) and -f (force). */
static int removePath(const char *path, int force, int depth) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        if (force) return 0;
        fprintf(stderr, "rm: %s: %s\n", path, strerror(errno));
        return 1;
    }
    if (S_ISDIR(st.st_mode)) {
        if (depth > 32) {
            fprintf(stderr, "rm: %s: too deep\n", path);
            return 1;
        }
        DIR *dir = opendir(path);
        if (!dir) {
            if (!force) {
                fprintf(stderr, "rm: %s: %s\n", path, strerror(errno));
                return 1;
            }
        } else {
            struct dirent *entry;
            while ((entry = readdir(dir))) {
                if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
                char child[4096];
                snprintf(child, sizeof child, "%s/%s", path, entry->d_name);
                removePath(child, force, depth + 1);
            }
            closedir(dir);
        }
        if (rmdir(path) != 0 && !force) {
            fprintf(stderr, "rm: %s: %s\n", path, strerror(errno));
            return 1;
        }
        return 0;
    }
    if (unlink(path) != 0 && !force) {
        fprintf(stderr, "rm: %s: %s\n", path, strerror(errno));
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    int recursive = 0, force = 0;
    int first = 1;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            for (const char *f = argv[i] + 1; *f; f++) {
                if (*f == 'r' || *f == 'R') recursive = 1;
                else if (*f == 'f') force = 1;
                else {
                    fprintf(stderr, "rm: unsupported option -%c (supports -r -f)\n", *f);
                    return 1;
                }
            }
            first = i + 1;
        }
    }
    if (first >= argc) {
        fprintf(stderr, "rm: missing operand\n");
        return 1;
    }
    int rc = 0;
    for (int i = first; i < argc; i++) {
        struct stat st;
        if (lstat(argv[i], &st) == 0 && S_ISDIR(st.st_mode) && !recursive) {
            fprintf(stderr, "rm: %s: is a directory\n", argv[i]);
            rc = 1;
            continue;
        }
        rc |= removePath(argv[i], force, 0);
    }
    return rc;
}