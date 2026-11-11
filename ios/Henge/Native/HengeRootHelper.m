#import "HengeRootHelper.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long bounded_integer(NSDictionary *report,NSString *key,long long maximum)
{
    id value=report[key];
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return -1;
    long long n=[value longLongValue];
    return n>=0 && n<=maximum && [value doubleValue]==(double)n?n:-1;
}
static long long bounded_count(NSDictionary *report,NSString *key)
{
    return bounded_integer(report,key,256);
}

static double monotonic_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static char *run_helper(const char *operation, int image, int witness)
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
        // Keep action sources away from stdio and the fixed image/witness target FDs 3/4.
        if (!error) {
            int high[2] = {fcntl(pipes[0], F_DUPFD_CLOEXEC, 10), -1};
            if (high[0] >= 0) high[1] = fcntl(pipes[1], F_DUPFD_CLOEXEC, 10);
            int saved = errno;
            close(pipes[0]); close(pipes[1]);
            pipes[0] = high[0]; pipes[1] = high[1];
            if (high[0] < 0 || high[1] < 0) error = saved;
        }
        if (!error) error = posix_spawn_file_actions_init(&actions);
        if (!error) initialized = YES;
        if (!error) error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        if (!error) error = posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
        if (!error) error = posix_spawn_file_actions_addclose(&actions, pipes[0]);
        if (!error) error = posix_spawn_file_actions_addclose(&actions, pipes[1]);
        if (!error) error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        if (!error && image >= 0) error = posix_spawn_file_actions_adddup2(&actions, image, 3);
        if (!error && image >= 0) error = posix_spawn_file_actions_addclose(&actions, image);
        if (!error && witness >= 0) error = posix_spawn_file_actions_adddup2(&actions, witness, 4);
        if (!error && witness >= 0) error = posix_spawn_file_actions_addclose(&actions, witness);
        char *argv[] = {(char *)path.fileSystemRepresentation, (char *)operation, NULL};
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
            ![report[@"schema"] isEqual:@1] || ![report[@"operation"] isEqual:@(operation)] ||
            ![report[@"root"] isEqual:@YES] || ![report[@"uid"] isEqual:@0] ||
            ![report[@"euid"] isEqual:@0] || ![report[@"gid"] isEqual:@0] ||
            ![report[@"egid"] isEqual:@0] || ![report[@"payload_verified"] isEqual:@YES]) return NULL;
        if ((!strcmp(operation,"attest-caller-v1") || !strcmp(operation,"check-write-authority-v1")) &&
            (![report[@"caller_verified"] isEqual:@YES] ||
             ![report[@"caller_no_sandbox_entitled"] isEqual:@YES] ||
             ![report[@"caller_executable_verified"] isEqual:@YES] ||
             bounded_integer(report,@"caller_uid",UINT32_MAX-1LL)<0 ||
             bounded_integer(report,@"caller_pid",INT32_MAX)<=1)) return NULL;
        if (!strcmp(operation,"check-write-authority-v1") &&
            (![report[@"write_authority_verified"] isEqual:@YES] ||
             ![report[@"image_inspected"] isEqual:@YES] ||
             ![report[@"exclusive_lease_verified"] isEqual:@YES] ||
             ![report[@"media_inventory_verified"] isEqual:@YES] ||
             ![report[@"image_modified"] isEqual:@NO] ||
             ![report[@"image_attached"] isEqual:@NO] ||
             ![report[@"volume_mounted"] isEqual:@NO])) return NULL;
        if (!strcmp(operation,"recover-workspaces-v1")) {
            long long total=bounded_count(report,@"enumerated"),candidates=bounded_count(report,@"candidates"),
                recovered=bounded_count(report,@"recovered"),busy=bounded_count(report,@"busy"),
                retained=bounded_count(report,@"retained"),changed=bounded_count(report,@"changed"),
                ignored=bounded_count(report,@"ignored");
            BOOL complete=!(busy || retained || changed || ignored);
            id present=report[@"workspace_parent_present"];
            if (total<0 || candidates<0 || recovered<0 || busy<0 || retained<0 || changed<0 || ignored<0 ||
                candidates+ignored!=total || recovered+busy+retained+changed!=candidates ||
                ![report[@"namespace_bounded"] isEqual:@YES] ||
                ![report[@"original_guest_disk_accessed"] isEqual:@NO] ||
                ![report[@"volume_mounted"] isEqual:@NO] ||
                (![present isEqual:@YES] && ![present isEqual:@NO]) ||
                ([present isEqual:@NO] && total) ||
                ![report[@"cleanup_complete"] isEqual:@(complete)]) return NULL;
        } else if (image < 0) {
            if (![report[@"guest_disk_accessed"] isEqual:@NO]) return NULL;
        } else if (![report[@"image_inspected"] isEqual:@YES] ||
                   ![report[@"exclusive_lease_verified"] isEqual:@YES] ||
                   ![report[@"media_inventory_verified"] isEqual:@YES] ||
                   ![report[@"image_modified"] isEqual:@NO] ||
                   ![report[@"image_attached"] isEqual:@NO] ||
                   ![report[@"volume_mounted"] isEqual:@NO]) return NULL;
        output[used] = '\0';
        return strdup(output);
    }
}

char *henge_root_helper_probe(void)
{
    return run_helper("probe-v1", -1, -1);
}

char *henge_root_helper_recover_workspaces(void)
{
    return run_helper("recover-workspaces-v1", -1, -1);
}
char *henge_root_helper_attest_caller(void)
{
    return run_helper("attest-caller-v1", -1, -1);
}

char *henge_root_helper_inspect_disk(const char *path)
{
    if (!path) return NULL;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat info;
    int high = -1;
    if (!fstat(fd, &info) && S_ISREG(info.st_mode)) high = fcntl(fd, F_DUPFD_CLOEXEC, 10);
    close(fd);
    if (high < 0) return NULL;
    char *report = run_helper("inspect-image-v1", high, -1);
    close(high);
    return report;
}

char *henge_root_helper_check_write_authority(const char *path)
{
    if (!path) return NULL;
    // Open both capabilities in the app, before acquiring root persona. The
    // helper never opens a caller-selected source path with root write access.
    int readFD=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    int writeFD=open(path,O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    struct stat a,b;int highRead=-1,highWrite=-1;
    if (readFD>=0 && writeFD>=0 && !fstat(readFD,&a) && !fstat(writeFD,&b) &&
        S_ISREG(a.st_mode) && a.st_dev==b.st_dev && a.st_ino==b.st_ino) {
        highRead=fcntl(readFD,F_DUPFD_CLOEXEC,10);
        if (highRead>=0) highWrite=fcntl(writeFD,F_DUPFD_CLOEXEC,10);
    }
    if(readFD>=0)close(readFD);
    if(writeFD>=0)close(writeFD);
    char *report=NULL;
    if(highRead>=0 && highWrite>=0)report=run_helper("check-write-authority-v1",highRead,highWrite);
    if(highRead>=0)close(highRead);
    if(highWrite>=0)close(highWrite);
    return report;
}
