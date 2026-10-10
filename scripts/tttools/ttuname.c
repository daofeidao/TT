#include <stdio.h>
#include <string.h>
#include <sys/utsname.h>

/* ttbin/uname: print system identity (-a -s -n -r -v -m). */
int main(int argc, char **argv) {
    struct utsname u;
    if (uname(&u) != 0) {
        fprintf(stderr, "uname: failed\n");
        return 1;
    }
    const char *flag = argc > 1 ? argv[1] : "-s";
    if (strcmp(flag, "-a") == 0) {
        printf("%s %s %s %s %s\n", u.sysname, u.nodename, u.release, u.version, u.machine);
    } else if (strcmp(flag, "-s") == 0) {
        printf("%s\n", u.sysname);
    } else if (strcmp(flag, "-n") == 0) {
        printf("%s\n", u.nodename);
    } else if (strcmp(flag, "-r") == 0) {
        printf("%s\n", u.release);
    } else if (strcmp(flag, "-v") == 0) {
        printf("%s\n", u.version);
    } else if (strcmp(flag, "-m") == 0) {
        printf("%s\n", u.machine);
    } else {
        fprintf(stderr, "uname: unsupported option %s\n", flag);
        return 1;
    }
    return 0;
}
