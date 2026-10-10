#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

/*
 * ttbin/ttfork: isolates where process creation dies on this device.
 *
 * Three phases, because "can this process fork at all" and "can a shell
 * survive forking" are different questions:
 *
 *   1. plain   fork() + _exit()          is fork itself budgeted on this device?
 *   2. exec    fork() + execl()          can a nested bundled binary be launched?
 *   3. parent  fork() + exec, while the PARENT keeps running C code
 *                                        the shape a pipeline uses when one side
 *                                        is a shell builtin; this is the pattern
 *                                        that separates "platform limit" from
 *                                        "mksh's own fork path is broken".
 *
 * Outcome classification matters more than the pass/fail verdict here. An exec
 * that fails exits 126 and a program missing from PATH exits 127; an earlier
 * revision of this probe treated anything below 128 as success, so both of the
 * most relevant failure modes were silently reported as ALL_OK. The sentinel
 * codes below (125/126/127) are safe because the exec target returns 0.
 */

#define R_FORK_FAILED (-1)
#define R_EXEC_FAILED (-2)
#define R_WAIT_FAILED (-3)
#define R_SIGNAL_BASE 128

static const char *programPath = NULL;

struct Outcome {
    int forkFailed;        /* fork() itself returned < 0 */
    int execFailed;        /* child could not exec, or target exited 125/126/127 */
    int waitFailed;        /* waitpid itself failed */
    int signalled;         /* child died from a signal; stores the signal number */
};

static const char *verdict(const struct Outcome *out) {
    if (out->forkFailed) return "BROKEN:fork";
    if (out->execFailed) return "BROKEN:exec";
    if (out->waitFailed) return "BROKEN:wait";
    if (out->signalled) return "BROKEN:signal";
    return "ALL_OK";
}

static void record(struct Outcome *out, int rc) {
    switch (rc) {
    case R_FORK_FAILED:
        out->forkFailed = 1;
        break;
    case R_EXEC_FAILED:
        out->execFailed = 1;
        break;
    case R_WAIT_FAILED:
        out->waitFailed = 1;
        break;
    default:
        if (rc >= R_SIGNAL_BASE && out->signalled == 0) {
            out->signalled = rc - R_SIGNAL_BASE;
        }
        break;
    }
}

/* Reap one child and describe precisely how it ended. */
static int reap(pid_t pid, char *detail, size_t detailSize) {
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        snprintf(detail, detailSize, "waitpid 失败 errno=%d（%s）", errno, strerror(errno));
        return R_WAIT_FAILED;
    }
    if (WIFSIGNALED(status)) {
        int sig = WTERMSIG(status);
        snprintf(detail, detailSize, "被信号 %d 终止（%s）", sig, strsignal(sig));
        return R_SIGNAL_BASE + sig;
    }
    if (WIFEXITED(status)) {
        int code = WEXITSTATUS(status);
        switch (code) {
        case 125:
            snprintf(detail, detailSize, "退出码 125：子进程初始化失败（探针 sentinel）");
            return R_EXEC_FAILED;
        case 126:
            snprintf(detail, detailSize, "退出码 126：execl 失败，程序无法启动（%s）", strerror(errno));
            return R_EXEC_FAILED;
        case 127:
            snprintf(detail, detailSize, "退出码 127：程序在 PATH 中不存在");
            return R_EXEC_FAILED;
        default:
            snprintf(detail, detailSize, "正常退出 rc=%d", code);
            return code;
        }
    }
    snprintf(detail, detailSize, "子进程处于停止/继续状态（WIFSTOPPED/WIFCONTINUED）");
    return R_WAIT_FAILED;
}

/*
 * mode 0: fork + _exit
 * mode 1: fork + execl(programPath)
 * mode 2: fork + execl, and the parent keeps doing shell-like work while the
 *         child is alive (the pipeline shape)
 */
static int attempt(int mode, int index, char *detail, size_t detailSize) {
    pid_t pid = fork();
    if (pid < 0) {
        snprintf(detail, detailSize, "fork() 失败 errno=%d（%s）", errno, strerror(errno));
        return R_FORK_FAILED;
    }
    if (pid == 0) {
        if (mode == 0) {
            _exit(0);
        }
        execl(programPath, "ttprobe", (char *)NULL);
        _exit(126);
    }

    if (mode == 2) {
        /* Parent must keep running C code with a live child, exactly as a shell
         * does when the other side of a pipeline is a builtin. If the device
         * cannot sustain this, a pipeline dies here even though plain single
         * commands succeed. */
        char scratch[64];
        int n = snprintf(scratch, sizeof scratch, "  父进程存活 iter %d\n", index);
        if (n > 0) {
            fwrite(scratch, 1, (size_t)n, stdout);
            fflush(stdout);
        }
    }
    return reap(pid, detail, detailSize);
}

static void run_phase(const char *title, int mode, int iterations, struct Outcome *out) {
    printf("-- %s --\n", title);
    for (int i = 1; i <= iterations; i++) {
        char detail[256] = "";
        int rc = attempt(mode, i, detail, sizeof detail);
        record(out, rc);
        int bad = (rc < 0) || (rc >= R_SIGNAL_BASE);
        printf("  iter %2d: %s%s\n", i, detail, bad ? "  <== 失败" : "");
        if (rc < 0) {
            printf("  result: 第 %d 次迭代即失败，后续未测\n", i);
            return;
        }
    }
    printf("  result: %s\n", verdict(out));
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "用法: ttfork <要 exec 的程序路径> [迭代次数]\n");
        fprintf(stderr, "示例: ttfork <App>/ttprobe 8\n");
        return 2;
    }
    programPath = argv[1];
    int iterations = (argc > 2) ? atoi(argv[2]) : 8;
    if (iterations < 1 || iterations > 64) {
        iterations = 8;
    }

    struct Outcome plain = {0, 0, 0, 0};
    struct Outcome execed = {0, 0, 0, 0};
    struct Outcome parentPhase = {0, 0, 0, 0};

    printf("TT_FORK_BEGIN prog=%s n=%d\n", programPath, iterations);

    run_phase("phase1 纯 fork + _exit", 0, iterations, &plain);
    run_phase("phase2 fork + exec（拉起嵌套二进制）", 1, iterations, &execed);
    run_phase("phase3 fork + exec，父进程同时继续执行（管道形态）", 2, iterations, &parentPhase);

    printf("TT_FORK_SUMMARY plain=%s exec=%s parent=%s\n",
           verdict(&plain), verdict(&execed), verdict(&parentPhase));
    if (plain.signalled) printf("TT_FORK_SIGNAL plain=%d（%s）\n", plain.signalled, strsignal(plain.signalled));
    if (execed.signalled) printf("TT_FORK_SIGNAL exec=%d（%s）\n", execed.signalled, strsignal(execed.signalled));
    if (parentPhase.signalled) printf("TT_FORK_SIGNAL parent=%d（%s）\n", parentPhase.signalled, strsignal(parentPhase.signalled));

    if (execed.execFailed) {
        printf("TT_FORK_HINT exec 阶段无法拉起嵌套二进制：检查 build-mksh.sh 是否给 ttprobe/ttbin/* 执行了 codesign --entitlements\n");
    }
    if (plain.signalled == 0 && execed.signalled == 0 && parentPhase.signalled != 0) {
        printf("TT_FORK_HINT 仅 phase3 被信号终止：平台允许多子进程，崩溃来自「fork 之后父进程继续执行」这一形态\n");
    }
    if (plain.signalled == 0 && execed.signalled == 0 && parentPhase.signalled == 0) {
        printf("TT_FORK_HINT 三个阶段全部通过：平台的进程创建没有问题，mksh 若仍崩溃属其自身代码路径\n");
    }
    printf("TT_FORK_END\n");
    return 0;
}
