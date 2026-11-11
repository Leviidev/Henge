#import "HengeRootHelper.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double monotonic_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

char *henge_root_helper_probe(void)
{
    @autoreleasepool {
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"henge-root-helper"];
        if (access(path.fileSystemRepresentation, X_OK) != 0) return NULL;
        typedef int (*persona_fn)(const posix_spawnattr_t *, uid_t, uint32_t);
        typedef int (*identity_fn)(const posix_spawnattr_t *, uid_t);
        persona_fn persona = (persona_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        identity_fn uid = (identity_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        identity_fn gid = (identity_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
        if (!persona || !uid || !gid) return NULL;

        posix_spawnattr_t attr;
        if (posix_spawnattr_init(&attr)) return NULL;
        int error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
        if (!error) error = persona(&attr, 99, 1);
        if (!error) error = uid(&attr, 0);
        if (!error) error = gid(&attr, 0);
        int pipes[2] = {-1, -1};
        posix_spawn_file_actions_t actions;
        BOOL initialized = NO;
        if (!error && pipe(pipes)) error = errno;
        if (!error) error = posix_spawn_file_actions_init(&actions);
        if (!error) initialized = YES;
        if (!error) error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        if (!error) error = posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
        if (!error) error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        char *argv[] = {(char *)path.fileSystemRepresentation, "probe-v1", NULL};
        char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", NULL};
        pid_t child = -1;
        if (!error) error = posix_spawn(&child, path.fileSystemRepresentation, &actions, &attr, argv, env);
        if (initialized) posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attr);
        if (pipes[1] >= 0) close(pipes[1]);
        if (error) {
            if (pipes[0] >= 0) close(pipes[0]);
            NSLog(@"Henge root helper spawn failed: %d", error);
            return NULL;
        }
        char output[4096];
        size_t used = 0;
        int status = 0;
        BOOL reaped = NO, eof = NO, failed = NO;
        int flags = fcntl(pipes[0], F_GETFL);
        if (flags < 0 || fcntl(pipes[0], F_SETFL, flags | O_NONBLOCK)) failed = YES;
        double deadline = monotonic_now() + 3;
        while (!failed && (!reaped || !eof) && monotonic_now() < deadline) {
            struct pollfd p = {.fd = pipes[0], .events = POLLIN | POLLHUP};
            int ready = poll(&p, 1, 20);
            if (ready < 0 && errno != EINTR) { failed = YES; break; }
            if (ready > 0) {
                ssize_t n = read(pipes[0], output + used, sizeof(output) - used);
                if (n > 0) used += (size_t)n;
                else if (!n) eof = YES;
                else if (errno != EINTR && errno != EAGAIN) failed = YES;
                if (used == sizeof(output)) failed = YES;
            }
            if (!reaped) {
                pid_t result = waitpid(child, &status, WNOHANG);
                if (result == child) reaped = YES;
                else if (result < 0 && errno != EINTR) { failed = YES; reaped = YES; }
            }
        }
        close(pipes[0]);
        if (!reaped) {
            kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            failed = YES;
        }
        if (failed || !eof || !WIFEXITED(status) || WEXITSTATUS(status)) return NULL;
        NSData *data = [NSData dataWithBytes:output length:used];
        NSDictionary *report = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([report isKindOfClass:NSDictionary.class] && [report[@"payload_verified"] isEqual:@NO])
            NSLog(@"Henge bundled payload validation failed: %@", report[@"payload_verification"]);
        if (![report isKindOfClass:NSDictionary.class] ||
            ![report[@"schema"] isEqual:@1] || ![report[@"operation"] isEqual:@"probe-v1"] ||
            ![report[@"root"] isEqual:@YES] || ![report[@"uid"] isEqual:@0] ||
            ![report[@"euid"] isEqual:@0] || ![report[@"gid"] isEqual:@0] ||
            ![report[@"egid"] isEqual:@0] || ![report[@"payload_verified"] isEqual:@YES] ||
            ![report[@"guest_disk_accessed"] isEqual:@NO]) return NULL;
        output[used] = '\0';
        return strdup(output);
    }
}
