/* Developer-only native transaction control; never mounts or writes a volume. */
#import <Foundation/Foundation.h>
#include "HGGuestAttachment.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    @autoreleasepool {
        int checkVersion = argc == 3 && !strcmp(argv[2], "--system-version");
        int checkMount = checkVersion || (argc == 3 && !strcmp(argv[2], "--mount-readonly"));
        if (argc != 2 && !checkMount) return 64;
        int incoming = open(argv[1], O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        HGGuestDisk disk = {.fd = -1};
        HGGuestAttachment attachment = {0};
        const char *error = NULL, *cleanup = NULL;
        char *group = NULL, *version = NULL;
        int result = hg_guest_disk_inspect_fd(incoming, &disk, &error);
        if (!result) result = hg_guest_attachment_open(&disk, &attachment, &group, &error);
        if (!result && checkMount) result = hg_guest_attachment_mount_readonly(&attachment, &error);
        int mounted = checkMount && !result;
        if (!result && checkVersion)
            result = hg_guest_attachment_copy_system_version(&attachment, &version, &error);
        int closed = attachment.disk ? hg_guest_attachment_close(&attachment, &cleanup) : 0;
        printf("{\"passed\":%s,\"error\":\"%s\",\"cleanup_error\":\"%s\","
               "\"group\":%s,\"system_version\":%s,\"mount_check_passed\":%s,\"detached\":%s,\"unchanged\":%s}\n",
               !result && !closed ? "true" : "false", error ?: "", cleanup ?: "",
               group ?: "null", version ?: "null", mounted ? "true" : "false", !closed ? "true" : "false",
               hg_guest_disk_unchanged(&disk) ? "true" : "false");
        free(group);
        free(version);
        hg_guest_disk_close(&disk);
        if (incoming >= 0) close(incoming);
        return result || closed ? 1 : 0;
    }
}
