#ifndef HG_GUEST_ATTACHMENT_H
#define HG_GUEST_ATTACHMENT_H
#include "HGGuestDisk.h"
#include <limits.h>

typedef struct {
    char path[PATH_MAX];
    char bsd[64];
    uint64_t registry_id;
    dev_t directory_device;
    ino_t directory_inode;
} HGGuestReadonlyMount;

typedef struct {
    const HGGuestDisk *disk; /* Caller retains the exclusive lease until close. */
    char physical_bsd[64];
    uint64_t physical_registry_id;
    HGGuestReadonlyMount system_mount;
    HGGuestReadonlyMount data_mount;
} HGGuestAttachment;

/* Initialize attachment to zero before first use. Open attaches read-only
 * without mounting volumes; the separate mount API is an explicit developer
 * qualification path. No guest files are written by this transaction.
 * On success caller owns attachment and frees group JSON. On failure cleanup is
 * attempted before return; attachment-cleanup-required means devices remain.
 * Always call close before releasing the disk lease, including after failure. */
int hg_guest_attachment_open(const HGGuestDisk *disk, HGGuestAttachment *attachment,
                             char **group_json, const char **error);
int hg_guest_attachment_close(HGGuestAttachment *attachment, const char **error);
/* Mount fresh, owned System/Data identities read-only under private temporary
 * directories. Paths remain valid only until close; close unmounts before eject.
 * No payload files or guest configuration are written. */
int hg_guest_attachment_mount_readonly(HGGuestAttachment *attachment, const char **error);
#endif
