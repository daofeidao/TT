#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

/* ttbin/mv: move or rename files.
 * 同设备走 rename(2)；跨设备（EXDEV）退化为拷贝后删除。
 */

static int copyAndRemove(const char *from, const char *to, mode_t mode) {
    int in = open(from, O_RDONLY);
    if (in < 0) {
        fprintf(stderr, "mv: %s: %s\n", from, strerror(errno));
        return 1;
    }
    int out = open(to, O_WRONLY | O_CREAT | O_TRUNC, mode & 0777);
    if (out < 0) {
        close(in);
        fprintf(stderr, "mv: %s: %s\n", to, strerror(errno));
        return 1;
    }
    static char buffer[65536];
    ssize_t n;
    int rc = 0;
    while ((n = read(in, buffer, sizeof buffer)) > 0) {
        ssize_t written = 0;
        while (written < n) {
            ssize_t w = write(out, buffer + written, (size_t)(n - written));
            if (w <= 0) { rc = 1; break; }
            written += w;
        }
        if (rc) break;
    }
    if (n < 0) rc = 1;
    close(in);
    close(out);
    if (!rc && unlink(from) != 0) rc = 1;
    if (rc) fprintf(stderr, "mv: %s -> %s: %s\n", from, to, strerror(errno));
    return rc;
}

int main(int argc, char **argv) {
    int first = 1;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            fprintf(stderr, "mv: unsupported option %s\n", argv[i]);
            return 1;
        }
        first = i;
        break;
    }
    if (argc - first < 2) {
        fprintf(stderr, "mv: usage: mv SOURCE DEST\n");
        return 1;
    }
    if (argc - first > 2) {
        fprintf(stderr, "mv: only one destination supported\n");
        return 1;
    }
    const char *from = argv[first];
    const char *to = argv[first + 1];

    struct stat st;
    if (lstat(from, &st) != 0) {
        fprintf(stderr, "mv: %s: %s\n", from, strerror(errno));
        return 1;
    }
    if (rename(from, to) == 0) return 0;
    if (errno != EXDEV) {
        fprintf(stderr, "mv: %s -> %s: %s\n", from, to, strerror(errno));
        return 1;
    }
    if (S_ISDIR(st.st_mode)) {
        fprintf(stderr, "mv: %s: cross-device directory move unsupported\n", from);
        return 1;
    }
    return copyAndRemove(from, to, st.st_mode);
}