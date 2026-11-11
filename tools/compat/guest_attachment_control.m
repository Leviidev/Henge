/* Developer-only native transaction control; never mounts or writes a volume. */
#import <Foundation/Foundation.h>
#include "HGGuestAttachment.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) return 64;
        int incoming = open(argv[1], O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        HGGuestDisk disk = {.fd = -1};
        HGGuestAttachment attachment = {0};
        const char *error = NULL, *cleanup = NULL;
        char *group = NULL;
        int result = hg_guest_disk_inspect_fd(incoming, &disk, &error);
        if (!result) result = hg_guest_attachment_open(&disk, &attachment, &group, &error);
        int closed = attachment.disk ? hg_guest_attachment_close(&attachment, &cleanup) : 0;
        printf("{\"passed\":%s,\"error\":\"%s\",\"cleanup_error\":\"%s\","
               "\"group\":%s,\"detached\":%s,\"unchanged\":%s}\n",
               !result && !closed ? "true" : "false", error ?: "", cleanup ?: "",
               group ?: "null", !closed ? "true" : "false",
               hg_guest_disk_unchanged(&disk) ? "true" : "false");
        free(group);
        hg_guest_disk_close(&disk);
        if (incoming >= 0) close(incoming);
        return result || closed ? 1 : 0;
    }
}
