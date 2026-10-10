#include <stdio.h>
#include <time.h>
#include <string.h>

/* ttbin/date: print current time (local, or UTC with -u). */
int main(int argc, char **argv) {
    int utc = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-u") == 0) utc = 1;
    }
    time_t now = time(NULL);
    struct tm tmv;
    (utc ? gmtime_r : localtime_r)(&now, &tmv);
    char out[128];
    strftime(out, sizeof(out), "%a %b %e %H:%M:%S %Z %Y", &tmv);
    printf("%s\n", out);
    return 0;
}
