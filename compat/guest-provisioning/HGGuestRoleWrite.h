#ifndef HG_GUEST_ROLE_WRITE_H
#define HG_GUEST_ROLE_WRITE_H
#include "HGGuestClone.h"

typedef struct {
    char journal_name[128];
    struct stat journal_identity;
    uint32_t edited_blocks;
    int journal_durable;
    int image_durable;
} HGGuestRoleWriteReport;

/* Owned private copy only; never writes the borrowed source. Builds fresh
 * source/copy catalogs and the role plan internally. Writes an exclusive private
 * journal (old/new full blocks and offsets), syncs it and its parent BEFORE any
 * image write. Then revalidates each old block, writes, syncs and reads back.
 * A failure once journaling starts taints the clone permanently: discard it,
 * never mount/publish or replay old blocks. Journals are retained, including on
 * success, for the encompassing transaction's recovery/cleanup policy. This
 * primitive does NOT provide restart recovery, publication or mount authority.
 * Caller must serialize all operations and initialize the report to zero. */
int hg_guest_roles_write(HGGuestClone *clone,int restore,
                         HGGuestRoleWriteReport *report,const char **error);
#endif
