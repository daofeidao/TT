#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <errno.h>

/* ttbin/ls: minimal directory lister for the bundled mksh environment. */
static int cmpstr(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

int main(int argc, char **argv) {
    int showAll = 0;
    const char *path = ".";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-a") == 0 || strcmp(argv[i], "-la") == 0 || strcmp(argv[i], "-al") == 0) {
            showAll = 1;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "ls: unsupported option %s (only -a)\n", argv[i]);
            return 1;
        } else {
            path = argv[i];
        }
    }
    DIR *dir = opendir(path);
    if (!dir) {
        fprintf(stderr, "ls: %s: %s\n", path, strerror(errno));
        return 1;
    }
    char **names = NULL;
    size_t count = 0, capacity = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (!showAll && entry->d_name[0] == '.') continue;
        if (count == capacity) {
            capacity = capacity ? capacity * 2 : 64;
            names = realloc(names, capacity * sizeof(char *));
        }
        names[count++] = strdup(entry->d_name);
    }
    closedir(dir);
    qsort(names, count, sizeof(char *), cmpstr);
    for (size_t i = 0; i < count; i++) {
        char full[4096];
        snprintf(full, sizeof(full), "%s/%s", path, names[i]);
        struct stat st;
        int isDir = (lstat(full, &st) == 0) && S_ISDIR(st.st_mode);
        printf("%s%s\n", names[i], isDir ? "/" : "");
        free(names[i]);
    }
    free(names);
    return 0;
}
