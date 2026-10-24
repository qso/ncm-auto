/*
 * ncm-eventd — 用 macOS FSEvents 监听目录，事件驱动地调用转换脚本。
 * 空闲时阻塞在 run loop，不轮询、不扫盘。
 *
 * 用法: ncm-eventd <converter.sh> <watch-dir> [watch-dir ...]
 * 转换脚本以退出码 75 表示"还有文件在下载中/刚出现，需要稍后重试"。
 */
#include <CoreServices/CoreServices.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_dirty = 0;

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static void on_events(ConstFSEventStreamRef stream,
                      void *info,
                      size_t num_events,
                      void *event_paths,
                      const FSEventStreamEventFlags flags[],
                      const FSEventStreamEventId ids[]) {
    (void)stream; (void)info; (void)num_events;
    (void)event_paths; (void)flags; (void)ids;
    g_dirty = 1;
}

static int run_converter(const char *script) {
    pid_t pid = fork();
    if (pid < 0) return 1;
    if (pid == 0) {
        execl("/bin/bash", "bash", script, (char *)NULL);
        _exit(127);
    }
    int status = 0;
    for (;;) {
        pid_t r = waitpid(pid, &status, 0);
        if (r == pid) break;
        if (r < 0 && errno == EINTR) {
            if (g_stop) return 0;
            continue;
        }
        return 1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static void convert_until_settled(const char *script) {
    g_dirty = 0;
    usleep(3 * 1000 * 1000); /* 合并下载过程中的连续写事件 */
    g_dirty = 0;             /* 本次运行会处理之前累积的变化 */

    while (!g_stop) {
        int rc = run_converter(script);
        if (rc == 75) {
            /* 文件还在写入或太新，10 秒后重试（事件驱动，不是周期扫描） */
            sleep(10);
            continue;
        }
        break;
    }
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <converter.sh> <watch-dir> [watch-dir ...]\n", argv[0]);
        return 2;
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);

    CFMutableArrayRef paths = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (int i = 2; i < argc; i++) {
        struct stat st;
        if (stat(argv[i], &st) == 0 && S_ISDIR(st.st_mode)) {
            CFStringRef s = CFStringCreateWithCString(NULL, argv[i], kCFStringEncodingUTF8);
            if (s) {
                CFArrayAppendValue(paths, s);
                CFRelease(s);
            }
        } else {
            fprintf(stderr, "skip missing dir: %s\n", argv[i]);
        }
    }
    if (CFArrayGetCount(paths) == 0) {
        fprintf(stderr, "no watch dirs exist\n");
        return 3;
    }

    /* 启动时补扫一次，处理关机/退出期间下载的文件 */
    int rc = run_converter(argv[1]);
    while (rc == 75 && !g_stop) {
        sleep(10);
        rc = run_converter(argv[1]);
    }

    FSEventStreamContext ctx = {0, NULL, NULL, NULL, NULL};
    FSEventStreamRef stream = FSEventStreamCreate(
        NULL, &on_events, &ctx, paths,
        kFSEventStreamEventIdSinceNow, 1.0,
        kFSEventStreamCreateFlagFileEvents |
        kFSEventStreamCreateFlagNoDefer |
        kFSEventStreamCreateFlagWatchRoot);
    if (!stream) {
        fprintf(stderr, "FSEventStreamCreate failed\n");
        return 4;
    }

    FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    if (!FSEventStreamStart(stream)) {
        fprintf(stderr, "FSEventStreamStart failed\n");
        return 5;
    }

    fprintf(stderr, "ncm-eventd: watching %ld dir(s)\n", (long)CFArrayGetCount(paths));

    while (!g_stop) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, true);
        if (g_dirty) convert_until_settled(argv[1]);
    }

    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    CFRelease(paths);
    return 0;
}
