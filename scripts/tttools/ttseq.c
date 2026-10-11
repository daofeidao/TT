#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

/* ttbin/seq: print a sequence of numbers, one per line.
 * usage: seq [first [incr]] last
 */
int main(int argc, char **argv) {
    double first = 1.0, incr = 1.0, last;
    const char *fmt = "%g";
    int start = 1;
    int i;

    for (i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] == 'f') {   /* -f FORMAT */
            fmt = argv[++i];
            continue;
        }
        break;
    }

    switch (argc - i) {
    case 1: last = atof(argv[i]); break;
    case 2: first = atof(argv[i]); incr = 1.0; last = atof(argv[i + 1]); break;
    case 3: first = atof(argv[i]); incr = atof(argv[i + 1]); last = atof(argv[i + 2]); break;
    default:
        fprintf(stderr, "seq: 最多三个参数\n");
        return 1;
    }

    if (incr == 0.0) {
        fprintf(stderr, "seq: 步长不能为 0\n");
        return 1;
    }

    if (incr > 0.0) {
        if (first > last) return 0;
        for (double v = first; v <= last + 1e-9; v += incr) printf(fmt, v), printf("\n");
    } else {
        if (first < last) return 0;
        for (double v = first; v >= last - 1e-9; v += incr) printf(fmt, v), printf("\n");
    }
    (void)start;
    (void)errno;
    return 0;
}
