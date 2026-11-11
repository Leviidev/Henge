#ifndef HG_GUEST_MEDIA_H
#define HG_GUEST_MEDIA_H
#include "HGGuestDisk.h"

/* Read-only IOKit inventory of media whose disk-image ancestor resolves to the
 * inspected inode. The caller retains the disk lease. Caller frees JSON.
 * Does not attach, detach, mount or grant authority to modify any media. */
int hg_guest_media_copy(const HGGuestDisk *disk, char **json, const char **error);
/* Select one unencrypted/unlocked System + Data volume group from freshly
 * queried owned media. Holds no authority after the caller releases its lease.
 * This only reports identity; it never mounts or modifies a volume. */
int hg_guest_media_copy_sonoma_data(const HGGuestDisk *disk, char **json, const char **error);
#endif
