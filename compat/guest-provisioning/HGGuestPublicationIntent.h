#ifndef HG_GUEST_PUBLICATION_INTENT_H
#define HG_GUEST_PUBLICATION_INTENT_H
#include "HGGuestClone.h"
#include "HGGuestWorkspace.h"
#include "HGGuestWriteAuthority.h"

typedef struct {
    int directory_fd, record_fd;
    struct stat record_identity;
    unsigned char record[1024];
} HGGuestPublicationIntent;
#define HG_GUEST_PUBLICATION_INTENT_INIT { .directory_fd=-1, .record_fd=-1 }
typedef enum {
    HG_PUBLICATION_PAIR_UNKNOWN=0,
    HG_PUBLICATION_ORIGINAL_ACTIVE=1,
    HG_PUBLICATION_COPY_ACTIVE=2
} HGGuestPublicationPair;

/* Durable immutable record BEFORE any ownership handoff or exchange. Requires
 * an attested caller write authority, unchanged leased source/copy, restored
 * roles and empty media for both. Binds workspace/target-parent/original/copy
 * inodes, names, original metadata and the trusted build's payload ID. Copies
 * with tainted writes or incomplete role restoration are refused.
 * This does not prove guest activation, perform an exchange or allow VM boot.
 * The supervisor must separately qualify activation, snapshot invalidation,
 * atomic exchange, rollback and health/commit policy before publication.
 * Partial/complete records remain on failure/close; generic workspace cleanup
 * refuses their unknown name, preserving both disks for dedicated recovery. */
int hg_guest_publication_intent_create(const HGGuestWorkspace *workspace,
    const HGGuestClone *clone,const HGGuestWriteAuthority *authority,
    const char *trusted_payload_id,HGGuestPublicationIntent *intent,const char **error);
/* Read-only restart inspection from a verified workspace. Never reads a caller
 * path from the record; the target parent is supplied as an opened descriptor. */
int hg_guest_publication_intent_open(const HGGuestWorkspace *workspace,
    HGGuestPublicationIntent *intent,const char **error);
/* Classifies the two directory entries by retained inode identities. This is
 * evidence of rename position only, NOT permission to swap/delete or proof of
 * unchanged contents, media exclusion, activation or successful guest boot. */
int hg_guest_publication_intent_pair(const HGGuestPublicationIntent *intent,
    int target_parent_fd,HGGuestPublicationPair *pair,const char **error);
/* Match freshly retained original-source authority to the durable intent's
 * namespace, inode, size, owner/mode/flags and mtime. Refuses a swapped pair or
 * changed source metadata across restart. This is not a full-content hash. */
int hg_guest_publication_intent_authority_matches(const HGGuestPublicationIntent *intent,
    const HGGuestWriteAuthority *authority,const char **error);
void hg_guest_publication_intent_close(HGGuestPublicationIntent *intent);
#endif
