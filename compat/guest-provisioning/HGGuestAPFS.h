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

#define HG_APFS_MAX_RECORDS 4096
typedef struct {
    HGGuestAPFSVolume volume;
    uint64_t first_checkpoint_xid, last_checkpoint_xid;
} HGGuestAPFSRecord;
typedef struct {
    uint32_t block_size, checkpoint_count, record_count;
    uint64_t latest_checkpoint_xid;
    HGGuestAPFSRecord records[HG_APFS_MAX_RECORDS];
} HGGuestAPFSCatalog;
/* Strict read-only catalog of all distinct NX checkpoints present in the
 * descriptor area, deduplicating physical volume records. Fails if any candidate
 * cannot be fully resolved; does not silently discard older checkpoints.
 * Caller frees the catalog. Still not rewrite/mount authority. */
int hg_guest_apfs_copy_catalog(const HGGuestDisk *disk, HGGuestAPFSCatalog **catalog,
                               const char **error);
#endif
