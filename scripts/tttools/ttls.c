#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <time.h>
#include <errno.h>

/* ttbin/ls: directory lister for the bundled mksh environment. Supports -a, -l. */
static int cmpstr(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void mode_string(mode_t mode, char *out) {
    char type = '-';
    if (S_ISDIR(mode)) type = 'd';
    else if (S_ISLNK(mode)) type = 'l';
    else if (S_ISCHR(mode)) type = 'c';
    else if (S_ISBLK(mode)) type = 'b';
    else if (S_ISFIFO(mode)) type = 'p';
    else if (S_ISSOCK(mode)) type = 's';

    out[0] = type;
    out[1] = (mode & S_IRUSR) ? 'r' : '-';
    out[2] = (mode & S_IWUSR) ? 'w' : '-';
    out[3] = (mode & S_IXUSR) ? 'x' : '-';
    out[4] = (mode & S_IRGRP) ? 'r' : '-';
    out[5] = (mode & S_IWGRP) ? 'w' : '-';
    out[6] = (mode & S_IXGRP) ? 'x' : '-';
    out[7] = (mode & S_IROTH) ? 'r' : '-';
    out[8] = (mode & S_IWOTH) ? 'w' : '-';
    out[9] = (mode & S_IXOTH) ? 'x' : '-';
    out[10] = '\0';
}

int main(int argc, char **argv) {
    int showAll = 0;
    int longFormat = 0;
    const char *path = ".";
    int pathSet = 0;

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            for (const char *flag = argv[i] + 1; *flag; flag++) {
                if (*flag == 'a') showAll = 1;
                else if (*flag == 'l') longFormat = 1;
                else {
                    fprintf(stderr, "ls: unsupported option -%c (supports -a -l)\n", *flag);
                    return 1;
                }
            }
        } else if (!pathSet) {
            path = argv[i];
            pathSet = 1;
        } else {
            fprintf(stderr, "ls: only one path operand supported\n");
            return 1;
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
            if (!names) { closedir(dir); return 1; }
        }
        names[count++] = strdup(entry->d_name);
    }
    closedir(dir);
    qsort(names, count, sizeof(char *), cmpstr);

    if (longFormat) {
        printf("total 0\n");
        for (size_t i = 0; i < count; i++) {
            char full[4096];
            snprintf(full, sizeof(full), "%s/%s", path, names[i]);
            struct stat st;
            if (lstat(full, &st) == 0) {
                char mode[12];
                mode_string(st.st_mode, mode);
                char timebuf[32];
                struct tm tmv;
                time_t mtime = st.st_mtime;
                localtime_r(&mtime, &tmv);
                strftime(timebuf, sizeof(timebuf), "%b %d %H:%M", &tmv);
                printf("%s %10lld %s %s", mode, (long long)st.st_size, timebuf, names[i]);
                if (S_ISDIR(st.st_mode)) printf("/");
                printf("\n");
            } else {
                printf("?????????? %10s %s %s\n", "-", "-", names[i]);
            }
            free(names[i]);
        }
    } else {
        for (size_t i = 0; i < count; i++) {
            char full[4096];
            snprintf(full, sizeof(full), "%s/%s", path, names[i]);
            struct stat st;
            int isDir = (lstat(full, &st) == 0) && S_ISDIR(st.st_mode);
            printf("%s%s\n", names[i], isDir ? "/" : "");
            free(names[i]);
        }
    }
    free(names);
    return 0;
}