#ifndef HG_GUEST_PUBLICATION_METADATA_H
#define HG_GUEST_PUBLICATION_METADATA_H
#include "HGGuestPublicationIntent.h"
/* Prepare the retained PRIVATE copy's UID/GID/mode for the attested owner, or
 * restore its original helper-private metadata after an abandoned handoff.
 * Requires durable intent, original-active pair, unchanged source authority,
 * unchanged exclusively leased copy and empty media. The copy never leaves its
 * private directory here. Both source bytes and source metadata stay untouched.
 * Any failure after a metadata syscall taints the copy (discard/recovery only).
 * No exchange, snapshot invalidation, activation or boot permission is granted.
 * Caller must retain/reattest its live peer separately through the transaction. */
int hg_guest_publication_metadata_set(const HGGuestPublicationIntent *intent,
    HGGuestClone *clone,const HGGuestWriteAuthority *authority,int restore_private,
    const char **error);
#endif
