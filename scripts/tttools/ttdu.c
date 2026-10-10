#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>

/* ttbin/du: report disk usage. Supports -s (summarize) and -h (human readable). */

static void humanize(unsigned long long bytes, int human, char *out, size_t outSize) {
    if (!human) {
        snprintf(out, outSize, "%llu", bytes);
        return;
    }
    const char *units[] = { "B", "K", "M", "G", "T" };
    double value = (double)bytes;
    int index = 0;
    while (value >= 1024 && index < 4) { value /= 1024; index++; }
    if (index == 0) snprintf(out, outSize, "%.0f%s", value, units[index]);
    else snprintf(out, outSize, "%.1f%s", value, units[index]);
}

static unsigned long long sizeOf(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    return (unsigned long long)st.st_blocks * 512;
}

static unsigned long long walk(const char *path, int depth) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    if (!S_ISDIR(st.st_mode)) return sizeOf(path);
    if (depth > 24) return 0;

    DIR *dir = opendir(path);
    if (!dir) return sizeOf(path);

    unsigned long long total = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        char child[4096];
        snprintf(child, sizeof child, "%s/%s", path, entry->d_name);
        total += walk(child, depth + 1);
    }
    closedir(dir);
    return total;
}

int main(int argc, char **argv) {
    int summarize = 0, human = 0;
    const char *paths[64];
    int pathCount = 0;

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            for (const char *f = argv[i] + 1; *f; f++) {
                if (*f == 's') summarize = 1;
                else if (*f == 'h') human = 1;
                else {
                    fprintf(stderr, "du: unsupported option -%c (supports -s -h)\n", *f);
                    return 1;
                }
            }
        } else if (pathCount < 64) {
            paths[pathCount++] = argv[i];
        }
    }
    if (pathCount == 0) paths[pathCount++] = ".";

    int rc = 0;
    for (int i = 0; i < pathCount; i++) {
        struct stat st;
        if (lstat(paths[i], &st) != 0) {
            fprintf(stderr, "du: %s: %s\n", paths[i], strerror(errno));
            rc = 1;
            continue;
        }
        unsigned long long total = walk(paths[i], 0);
        char formatted[32];
        humanize(total, human, formatted, sizeof formatted);
        if (summarize || pathCount > 1) printf("%8s\t%s\n", formatted, paths[i]);
        else printf("%s\n", formatted);
    }
    return rc;
}