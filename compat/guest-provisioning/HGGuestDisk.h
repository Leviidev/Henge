#ifndef HG_GUEST_DISK_H
#define HG_GUEST_DISK_H
#include <stdint.h>
#include <sys/stat.h>

typedef struct {
    int fd; /* Independent read-only descriptor, exclusive flock until close. */
    struct stat identity;
    uint64_t first_apfs_lba;
    uint64_t last_apfs_lba;
    uint32_t partitions;
    unsigned char disk_uuid[16];
} HGGuestDisk;

/* Reopen an already readable regular file and match its inode before reading.
 * This never upgrades caller permissions, writes, attaches or mounts an image.
 * Only validated 512-byte-sector GPT images with one ordinary APFS partition
 * are currently accepted. Incoming descriptors and their locks are untouched. */
int hg_guest_disk_inspect_fd(int incoming, HGGuestDisk *disk, const char **error);
int hg_guest_disk_unchanged(const HGGuestDisk *disk);
void hg_guest_disk_close(HGGuestDisk *disk);
#endif
