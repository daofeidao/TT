#include <stdio.h>
#include <unistd.h>
#include <sys/utsname.h>

/*
 * ttprobe: container-exec control binary.
 * Spawned by the app to answer one question: can this process start
 * executables that live inside its own app container, while system
 * paths like /bin/sh are rejected with EPERM?
 */
int main(int argc, char **argv) {
    char cwd[1024];
    if (getcwd(cwd, sizeof(cwd)) == NULL) {
        cwd[0] = '?';
        cwd[1] = '\0';
    }
    struct utsname u;
    if (uname(&u) != 0) {
        u.sysname[0] = '?';
        u.sysname[1] = '\0';
        u.release[0] = '?';
        u.release[1] = '\0';
    }
    printf("TT_PROBE_OK uid=%d euid=%d cwd=%s sys=%s rel=%s argc=%d\n",
           (int)getuid(), (int)geteuid(), cwd, u.sysname, u.release, argc);
    return 0;
}
