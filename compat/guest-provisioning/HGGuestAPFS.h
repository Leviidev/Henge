#ifndef HG_GUEST_APFS_H
#define HG_GUEST_APFS_H
#include "HGGuestDisk.h"

typedef struct {
    uint64_t oid, xid, physical_block, flags;
    unsigned char uuid[16], group_uuid[16];
    uint16_t role;
} HGGuestAPFSVolume;
typedef struct {
    uint32_t block_size, volume_count;
    uint64_t block_count, checkpoint_xid;
    HGGuestAPFSVolume volumes[100];
} HGGuestAPFS;

/* Read-only bounded checkpoint/object-map traversal, under the caller's existing
 * image lease. Never scans file contents, patches roles, attaches or mounts.
 * Reports the latest valid checkpoint only; not authority for an image rewrite. */
int hg_guest_apfs_inspect(const HGGuestDisk *disk, HGGuestAPFS *apfs, const char **error);
#endif
