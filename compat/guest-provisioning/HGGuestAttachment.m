#import <Foundation/Foundation.h>
#include "HGGuestAttachment.h"
#include "HGGuestMedia.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <time.h>
#include <unistd.h>

/* Fixed executable, fixed environment, no inherited descriptors except stdio.
 * Output is deliberately ignored: only fresh IOKit ancestry grants ownership. */
static int run_tool(const char *executable, char *const arguments[])
{
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions)) return -1;
    if (posix_spawnattr_init(&attributes)) {
        posix_spawn_file_actions_destroy(&actions); return -1;
    }
    int code = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    if (!code) code = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    if (!code) code = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    if (!code) code = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", NULL};
    pid_t child = -1;
    if (!code) code = posix_spawn(&child, executable, &actions, &attributes,
                                 arguments, environment);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (code) return -1;
    for (unsigned int i = 0; i < 150; i++) {
        int status = 0;
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) return WIFEXITED(status) && !WEXITSTATUS(status) ? 0 : -1;
        if (result < 0 && errno != EINTR) return -1;
        struct timespec delay = {0, 20000000};
        nanosleep(&delay, NULL);
    }
    kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    return -1;
}

static int run_hdik(char *const arguments[]) { return run_tool("/usr/sbin/hdik", arguments); }

static NSArray *inventory(const HGGuestDisk *disk, const char **error)
{
    char *json = NULL;
    if (hg_guest_media_copy(disk, &json, error)) return nil;
    NSData *bytes = [NSData dataWithBytes:json length:strlen(json)];
    free(json);
    id rows = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
    if (![rows isKindOfClass:NSArray.class]) { *error = "invalid-media-inventory"; return nil; }
    return rows;
}

static NSDictionary *physical(const HGGuestDisk *disk, NSArray *rows)
{
    NSDictionary *found = nil;
    for (NSDictionary *row in rows) {
        if ([row[@"writable"] isEqual:@YES]) return nil;
        if (![row[@"content"] isEqual:@"GUID_partition_scheme"] ||
            ![row[@"whole"] isEqual:@YES]) continue;
        if (found || [row[@"bytes"] unsignedLongLongValue] != (uint64_t)disk->identity.st_size)
            return nil;
        found = row;
    }
    return found;
}

static BOOL mount_matches(const HGGuestReadonlyMount *mount, const struct statfs *fs)
{
    char device[80];
    snprintf(device, sizeof(device), "/dev/%s", mount->bsd);
    return !strcmp(fs->f_fstypename, "apfs") && !strcmp(fs->f_mntfromname, device) &&
           !strcmp(fs->f_mntonname, mount->path) &&
           (fs->f_flags & (MNT_RDONLY | MNT_NOEXEC | MNT_NOSUID)) ==
                          (MNT_RDONLY | MNT_NOEXEC | MNT_NOSUID);
}

static int close_mount(HGGuestReadonlyMount *mount, NSArray *rows)
{
    if (!mount->path[0]) return 0;
    BOOL owned = NO;
    for (NSDictionary *row in rows) {
        if (!strcmp([row[@"bsd_name"] UTF8String], mount->bsd) &&
            [row[@"registry_id"] unsignedLongLongValue] == mount->registry_id) owned = YES;
    }
    struct statfs fs;
    if (!owned || statfs(mount->path, &fs)) return -1;
    if (!strcmp(fs.f_mntonname, mount->path)) {
        if (!mount_matches(mount, &fs) || unmount(mount->path, 0)) return -1;
    }
    struct stat directory;
    if (lstat(mount->path, &directory) || !S_ISDIR(directory.st_mode) ||
        directory.st_dev != mount->directory_device || directory.st_ino != mount->directory_inode ||
        rmdir(mount->path)) return -1;
    memset(mount, 0, sizeof(*mount));
    return 0;
}

static int open_mount(NSDictionary *row, HGGuestReadonlyMount *mount)
{
    strlcpy(mount->path, "/private/var/mnt/henge-guest-XXXXXX", sizeof(mount->path));
    if (!mkdtemp(mount->path)) { memset(mount, 0, sizeof(*mount)); return -1; }
    struct stat directory;
    if (lstat(mount->path, &directory) || !S_ISDIR(directory.st_mode)) return -1;
    mount->directory_device = directory.st_dev;
    mount->directory_inode = directory.st_ino;
    strlcpy(mount->bsd, [row[@"bsd_name"] UTF8String], sizeof(mount->bsd));
    mount->registry_id = [row[@"registry_id"] unsignedLongLongValue];
    char device[80];
    snprintf(device, sizeof(device), "/dev/%s", mount->bsd);
    char *arguments[] = {"mount_apfs", "-o", "rdonly,nobrowse,noexec,nosuid", device, mount->path, NULL};
    int result = run_tool("/sbin/mount_apfs", arguments);
    struct statfs fs;
    return !result && !statfs(mount->path, &fs) && mount_matches(mount, &fs) ? 0 : -1;
}

int hg_guest_attachment_mount_readonly(HGGuestAttachment *attachment, const char **error)
{
    if (!attachment || !attachment->disk || !error) return -1;
    if (attachment->system_mount.path[0] || attachment->data_mount.path[0]) {
        *error = "volumes-already-mounted"; return -1;
    }
    @autoreleasepool {
        NSArray *rows = inventory(attachment->disk, error);
        NSDictionary *owned = rows ? physical(attachment->disk, rows) : nil;
        if (!owned || attachment->physical_registry_id != [owned[@"registry_id"] unsignedLongLongValue] ||
            strcmp(attachment->physical_bsd, [owned[@"bsd_name"] UTF8String])) {
            *error = "attachment-identity-changed"; return -1;
        }
        char *json = NULL;
        if (hg_guest_media_copy_volume_group(attachment->disk, &json, error)) return -1;
        NSData *bytes = [NSData dataWithBytes:json length:strlen(json)];
        free(json);
        NSDictionary *group = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
        if (![group isKindOfClass:NSDictionary.class] || !group[@"system"] || !group[@"data"]) {
            *error = "unsupported-volume-group"; return -1;
        }
        if (open_mount(group[@"system"], &attachment->system_mount) ||
            open_mount(group[@"data"], &attachment->data_mount)) {
            *error = "readonly-mount-failed"; return -1;
        }
        if (!hg_guest_disk_unchanged(attachment->disk)) { *error = "image-identity-changed"; return -1; }
        *error = NULL;
        return 0;
    }
}

int hg_guest_attachment_close(HGGuestAttachment *attachment, const char **error)
{
    if (!attachment || !error || !attachment->disk) return -1;
    @autoreleasepool {
        for (unsigned int attempt = 0; attempt < 5; attempt++) {
            NSArray *rows = inventory(attachment->disk, error);
            if (!rows) { *error = "attachment-cleanup-required"; return -1; }
            if (!rows.count) {
                if (attachment->system_mount.path[0] || attachment->data_mount.path[0]) {
                    *error = "mount-cleanup-required"; return -1;
                }
                memset(attachment, 0, sizeof(*attachment)); *error = NULL; return 0;
            }
            NSDictionary *owned = physical(attachment->disk, rows);
            if (!owned || (attachment->physical_registry_id &&
                (attachment->physical_registry_id != [owned[@"registry_id"] unsignedLongLongValue] ||
                 strcmp(attachment->physical_bsd, [owned[@"bsd_name"] UTF8String])))) {
                *error = "attachment-cleanup-required"; return -1;
            }
            if (close_mount(&attachment->data_mount, rows) || close_mount(&attachment->system_mount, rows)) {
                *error = "mount-cleanup-required"; return -1;
            }
            char device[80];
            snprintf(device, sizeof(device), "/dev/%s", [owned[@"bsd_name"] UTF8String]);
            char *arguments[] = {"hdik", "-e", device, NULL};
            (void)run_hdik(arguments);
            struct timespec delay = {0, 100000000};
            nanosleep(&delay, NULL);
        }
        NSArray *rows = inventory(attachment->disk, error);
        if (rows && !rows.count) {
            memset(attachment, 0, sizeof(*attachment)); *error = NULL; return 0;
        }
        *error = "attachment-cleanup-required"; return -1;
    }
}

int hg_guest_attachment_open(const HGGuestDisk *disk, HGGuestAttachment *attachment,
                             char **group_json, const char **error)
{
    if (group_json) *group_json = NULL;
    if (!disk || !attachment || !group_json || !error) return -1;
    if (attachment->disk) { *error = "attachment-already-open"; return -1; }
    memset(attachment, 0, sizeof(*attachment));
    @autoreleasepool {
        NSArray *before = inventory(disk, error);
        if (!before) return -1;
        if (before.count) { *error = "image-already-attached"; return -1; }
        char path[PATH_MAX];
        struct stat current;
        if (fcntl(disk->fd, F_GETPATH, path) || lstat(path, &current) ||
            !S_ISREG(current.st_mode) || current.st_dev != disk->identity.st_dev ||
            current.st_ino != disk->identity.st_ino || !hg_guest_disk_unchanged(disk)) {
            *error = "image-identity-changed"; return -1;
        }
        attachment->disk = disk;
        char *arguments[] = {"hdik", "-nomount", "-drivekey", "write-protected=true", path, NULL};
        int launched = run_hdik(arguments);
        BOOL pathUnchanged = !lstat(path, &current) && S_ISREG(current.st_mode) &&
            current.st_dev == disk->identity.st_dev && current.st_ino == disk->identity.st_ino;
        NSArray *rows = inventory(disk, error);
        NSDictionary *owned = rows ? physical(disk, rows) : nil;
        if (owned) {
            strlcpy(attachment->physical_bsd, [owned[@"bsd_name"] UTF8String], sizeof(attachment->physical_bsd));
            attachment->physical_registry_id = [owned[@"registry_id"] unsignedLongLongValue];
        }
        if (!launched && pathUnchanged && owned &&
            !hg_guest_media_copy_volume_group(disk, group_json, error)) return 0;
        // A concurrent pathname replacement may have attached a different image.
        // Never eject that image using unverified tool output or a guessed name.
        const char *failure = !pathUnchanged ? "attachment-outcome-unknown" :
                             *error ?: "readonly-attachment-failed";
        const char *cleanup = NULL;
        if (hg_guest_attachment_close(attachment, &cleanup)) *error = cleanup;
        else *error = failure;
        return -1;
    }
}
