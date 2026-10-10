#include <stdio.h>
#include <unistd.h>
#include <pwd.h>

/* ttbin/whoami: print the effective user name. */
int main(void) {
    struct passwd *pw = getpwuid(geteuid());
    if (pw && pw->pw_name) {
        printf("%s\n", pw->pw_name);
        return 0;
    }
    printf("uid%d\n", (int)geteuid());
    return 0;
}
