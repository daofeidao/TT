#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/mount.h>

/* ttbin/df: report disk usage for a mounted path (default /). */
static void human(unsigned long long bytes, char *out, size_t n) {
    const char *units[] = {"B", "K", "M", "G", "T"};
    double value = (double)bytes;
    int idx = 0;
    while (value >= 1024 && idx < 4) {
        value /= 1024;
        idx++;
    }
    snprintf(out, n, idx ? "%.1f%s" : "%.0f%s", value, units[idx]);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/";
    struct statfs s;
    if (statfs(path, &s) != 0) {
        fprintf(stderr, "df: %s: %s\n", path, strerror(errno));
        return 1;
    }
    unsigned long long blockSize = (unsigned long long)s.f_bsize;
    unsigned long long total = (unsigned long long)s.f_blocks * blockSize;
    unsigned long long freeBlocks = (unsigned long long)s.f_bfree * blockSize;
    unsigned long long available = (unsigned long long)s.f_bavail * blockSize;
    char totalH[16], usedH[16], availH[16], capacity[16];
    human(total, totalH, sizeof(totalH));
    human(total - freeBlocks, usedH, sizeof(usedH));
    human(available, availH, sizeof(availH));
    if (total) {
        snprintf(capacity, sizeof(capacity), "%.0f%%", (double)(total - available) / (double)total * 100.0);
    } else {
        snprintf(capacity, sizeof(capacity), "-");
    }
    printf("Filesystem  Size  Used Avail Capacity Mounted on\n");
    printf("%-10s %4s  %4s %4s %8s %s\n", s.f_mntfromname, totalH, usedH, availH, capacity, s.f_mntonname);
    return 0;
}
