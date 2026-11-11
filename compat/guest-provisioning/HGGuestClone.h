#ifndef HG_GUEST_CLONE_H
#define HG_GUEST_CLONE_H
#include "HGGuestDisk.h"

typedef struct {
    const HGGuestDisk *source; /* Caller retains source lease throughout. */
    HGGuestDisk disk;         /* Independent read-only clone lease. */
    int directory_fd;
    char name[64];
    struct stat created_identity;
    int created;
} HGGuestClone;
#define HG_GUEST_CLONE_INIT { .disk = { .fd = -1 }, .directory_fd = -1 }

/* Caller initializes with HG_GUEST_CLONE_INIT. Parent must be an already opened
 * trusted private directory owned by the effective user (no group/other access).
 * Uses descriptor-based APFS cloning only, without a full-copy fallback.
 * Does not mount, alter the source, patch roles or publish a replacement disk. */
int hg_guest_clone_create(const HGGuestDisk *source, int private_parent_fd,
                          HGGuestClone *clone, const char **error);
/* Deletes only this clone's original inode/name after verified empty IOMedia
 * inventory. On failure retains ownership state for retry; never force-cleans
 * unknown media or a substituted path. Does not release the source lease. */
int hg_guest_clone_discard(HGGuestClone *clone, const char **error);
#endif
