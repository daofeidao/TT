#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <time.h>

/* ttbin/stat: show file metadata. */

static void modeString(mode_t mode, char *out) {
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

static void showOne(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        fprintf(stderr, "stat: %s: %s\n", path, strerror(errno));
        return;
    }
    char mode[12];
    modeString(st.st_mode, mode);
    char modified[64];
    struct tm tmv;
    time_t mtime = st.st_mtime;
    localtime_r(&mtime, &tmv);
    strftime(modified, sizeof modified, "%Y-%m-%d %H:%M:%S", &tmv);
    printf("  File: %s\n", path);
    printf("  Size: %lld\tBlocks: %lld\tIO Block: %lld\n",
           (long long)st.st_size, (long long)st.st_blocks, (long long)st.st_blksize);
    printf("Access: (%s)  Uid: %d  Gid: %d\n", mode, (int)st.st_uid, (int)st.st_gid);
    printf("Modify: %s\n", modified);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "stat: missing file operand\n");
        return 1;
    }
    int count = 0;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            fprintf(stderr, "stat: unsupported option %s\n", argv[i]);
            return 1;
        }
        if (count++) printf("\n");
        showOne(argv[i]);
    }
    return 0;
}