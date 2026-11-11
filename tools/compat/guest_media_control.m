/* Developer control only. Inspects an existing image and IOKit media; never
 * attaches, detaches, mounts or writes. Not required for release setup. */
#import <Foundation/Foundation.h>
#include "HGGuestDisk.h"
#include "HGGuestMedia.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) return 64;
        int fd = open(argv[1], O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        HGGuestDisk disk = {.fd = -1};
        const char *error = NULL;
        char *media = NULL;
        int result = hg_guest_disk_inspect_fd(fd, &disk, &error);
        if (!result) result = hg_guest_media_copy(&disk, &media, &error);
        printf("{\"passed\":%s,\"error\":\"%s\",\"media\":%s,\"unchanged\":%s}\n",
               result ? "false" : "true", error ?: "", media ?: "null",
               !result && hg_guest_disk_unchanged(&disk) ? "true" : "false");
        free(media);
        hg_guest_disk_close(&disk);
        if (fd >= 0) close(fd);
        return result ? 1 : 0;
    }
}
