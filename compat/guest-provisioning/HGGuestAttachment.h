#ifndef HG_GUEST_ATTACHMENT_H
#define HG_GUEST_ATTACHMENT_H
#include "HGGuestDisk.h"

typedef struct {
    const HGGuestDisk *disk; /* Caller retains the exclusive lease until close. */
    char physical_bsd[64];
    uint64_t physical_registry_id;
} HGGuestAttachment;

/* Initialize attachment to zero before first use. Native read-only attachment
 * transaction. No volumes are mounted or written.
 * On success caller owns attachment and frees group JSON. On failure cleanup is
 * attempted before return; attachment-cleanup-required means devices remain.
 * Always call close before releasing the disk lease, including after failure. */
int hg_guest_attachment_open(const HGGuestDisk *disk, HGGuestAttachment *attachment,
                             char **group_json, const char **error);
int hg_guest_attachment_close(HGGuestAttachment *attachment, const char **error);
#endif
