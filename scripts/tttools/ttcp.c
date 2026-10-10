#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/stat.h>

/* ttbin/cp: copy files; directories require -r. */

static int copyFile(const char *from, const char *to, mode_t mode) {
    int in = open(from, O_RDONLY);
    if (in < 0) {
        fprintf(stderr, "cp: %s: %s\n", from, strerror(errno));
        return 1;
    }
    int out = open(to, O_WRONLY | O_CREAT | O_TRUNC, mode & 0777);
    if (out < 0) {
        close(in);
        fprintf(stderr, "cp: %s: %s\n", to, strerror(errno));
        return 1;
    }
    char buffer[65536];
    ssize_t n;
    int rc = 0;
    while ((n = read(in, buffer, sizeof buffer)) > 0) {
        ssize_t written = 0;
        while (written < n) {
            ssize_t w = write(out, buffer + written, (size_t)(n - written));
            if (w <= 0) {
                fprintf(stderr, "cp: %s: %s\n", to, strerror(errno));
                rc = 1;
                break;
            }
            written += w;
        }
        if (rc) break;
    }
    if (n < 0) {
        fprintf(stderr, "cp: %s: %s\n", from, strerror(errno));
        rc = 1;
    }
    close(in);
    close(out);
    return rc;
}

static int copyTree(const char *from, const char *to, int depth) {
    if (depth > 32) {
        fprintf(stderr, "cp: %s: too deep\n", from);
        return 1;
    }
    DIR *dir = opendir(from);
    if (!dir) {
        fprintf(stderr, "cp: %s: %s\n", from, strerror(errno));
        return 1;
    }
    int rc = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        char src[4096], dst[4096];
        snprintf(src, sizeof src, "%s/%s", from, entry->d_name);
        snprintf(dst, sizeof dst, "%s/%s", to, entry->d_name);
        struct stat st;
        if (lstat(src, &st) != 0) {
            fprintf(stderr, "cp: %s: %s\n", src, strerror(errno));
            rc = 1;
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            if (mkdir(dst, st.st_mode & 0777) != 0 && errno != EEXIST) {
                fprintf(stderr, "cp: %s: %s\n", dst, strerror(errno));
                rc = 1;
                continue;
            }
            rc |= copyTree(src, dst, depth + 1);
        } else if (S_ISREG(st.st_mode)) {
            rc |= copyFile(src, dst, st.st_mode);
        }
    }
    closedir(dir);
    return rc;
}

int main(int argc, char **argv) {
    int recursive = 0;
    int first = 1;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            for (const char *f = argv[i] + 1; *f; f++) {
                if (*f == 'r' || *f == 'R') recursive = 1;
                else {
                    fprintf(stderr, "cp: unsupported option -%c (supports -r)\n", *f);
                    return 1;
                }
            }
            first = i + 1;
        }
    }
    if (argc - first < 2) {
        fprintf(stderr, "cp: usage: cp [-r] SOURCE DEST\n");
        return 1;
    }
    if (argc - first > 2) {
        fprintf(stderr, "cp: only one destination supported\n");
        return 1;
    }
    const char *from = argv[first];
    const char *to = argv[first + 1];

    struct stat st;
    if (lstat(from, &st) != 0) {
        fprintf(stderr, "cp: %s: %s\n", from, strerror(errno));
        return 1;
    }
    if (S_ISDIR(st.st_mode)) {
        if (!recursive) {
            fprintf(stderr, "cp: %s: is a directory\n", from);
            return 1;
        }
        struct stat dstStat;
        if (stat(to, &dstStat) == 0 && S_ISDIR(dstStat.st_mode)) {
            const char *leaf = strrchr(from, '/');
            char target[4096];
            snprintf(target, sizeof target, "%s/%s", to, leaf ? leaf + 1 : from);
            return copyTree(from, target, 0);
        }
        if (mkdir(to, st.st_mode & 0777) != 0 && errno != EEXIST) {
            fprintf(stderr, "cp: %s: %s\n", to, strerror(errno));
            return 1;
        }
        return copyTree(from, to, 0);
    }
    return copyFile(from, to, st.st_mode);
}