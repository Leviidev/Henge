#ifndef HG_GUEST_MEDIA_H
#define HG_GUEST_MEDIA_H
#include "HGGuestDisk.h"

/* Read-only IOKit inventory of media whose disk-image ancestor resolves to the
 * inspected inode. The caller retains the disk lease. Caller frees JSON.
 * Does not attach, detach, mount or grant authority to modify any media. */
int hg_guest_media_copy(const HGGuestDisk *disk, char **json, const char **error);
#endif
