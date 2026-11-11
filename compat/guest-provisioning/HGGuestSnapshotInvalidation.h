#ifndef HG_GUEST_SNAPSHOT_INVALIDATION_H
#define HG_GUEST_SNAPSHOT_INVALIDATION_H
#include "HGGuestPublicationIntent.h"
/* Quarantine the two fixed RAM-snapshot names beside machine disk.img into the
 * helper-private workspace, after durable publication intent and under retained
 * source authority. Persist a bounded inode receipt BEFORE the first rename.
 * No snapshot/image bytes are changed/deleted and no VM or disk is published.
 * Failure retains receipt and every known file; never retry through replacements.
 * The restart supervisor must complete partial moves before permitting boot. */
int hg_guest_snapshot_invalidate(const HGGuestPublicationIntent *intent,
    const HGGuestWriteAuthority *authority,const char **error);
/* Finish/revalidate a previously recorded quarantine after interruption.
 * Requires freshly attested retained authority with original still active.
 * Preflights every public/private inode before moving any remaining file;
 * replacements/duplicates are retained and refused. Complete is idempotent. */
int hg_guest_snapshot_invalidation_complete(const HGGuestPublicationIntent *intent,
    const HGGuestWriteAuthority *authority,const char **error);
/* Read-only proof that a bound durable receipt exists, both public names are
 * absent, and every recorded snapshot inode is in its fixed private location.
 * Valid for either retained publication inode-pair position. Not permission to
 * boot/publish/delete, and not a substitute for live leases/caller attestation. */
int hg_guest_snapshot_invalidation_verify(const HGGuestPublicationIntent *intent,
    int target_parent_fd,const char **error);
#endif
