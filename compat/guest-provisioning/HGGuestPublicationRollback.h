#ifndef HG_GUEST_PUBLICATION_ROLLBACK_H
#define HG_GUEST_PUBLICATION_ROLLBACK_H
#include "HGGuestPublicationIntent.h"
#include "HGGuestPeer.h"
typedef struct {
    int exchange_attempted;
    int durability_confirmed;
    HGGuestPublicationPair observed_pair;
} HGGuestRollbackReport;
/* Roll back an uncommitted copy-active pair using atomic RENAME_SWAP, retaining
 * the failed copy under the private name. If the original is already active,
 * revalidate and sync both directories without another exchange (restart retry).
 * Requires a freshly attested live app, app-opened write authority for the
 * CURRENT active inode, independently leased PRIVATE image, bound durable intent,
 * matching original owner/metadata, complete snapshot quarantine and empty media.
 * Both images stay exclusively leased through the operation. No bytes are
 * changed/deleted. Report is conservative after syscall/sync failures; caller
 * must close/reopen leases before reuse because rename can change inode ctime.
 * This is not a forward-publication API or permission to boot/commit. A complete
 * supervisor still has to enforce transaction/activation/health policy. */
int hg_guest_publication_rollback(const HGGuestPublicationIntent *intent,
    const HGGuestWriteAuthority *active,const HGGuestDisk *private_image,
    int expected_executable_fd,const HGGuestPeer *peer,
    HGGuestRollbackReport *report,const char **error);
#endif
