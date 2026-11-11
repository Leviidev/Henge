#ifndef HG_GUEST_WRITE_AUTHORITY_H
#define HG_GUEST_WRITE_AUTHORITY_H
#include "HGGuestDisk.h"
#include <sys/syslimits.h>

typedef struct {
    const HGGuestDisk *source; /* Borrowed validated read-only/exclusive lease. */
    int witness_fd, directory_fd;
    uid_t principal_uid;
    struct stat directory_identity;
    char name[NAME_MAX+1];
} HGGuestWriteAuthority;
#define HG_GUEST_WRITE_AUTHORITY_INIT { .witness_fd=-1, .directory_fd=-1 }

/* Requires an already-open caller-authorized O_RDWR descriptor to the exact
 * leased source inode. Never upgrades a read-only input or opens a source file
 * for writing. Derives/binds its existing parent/name from the descriptor.
 * Source must have one link, ordinary flags and no extended ACL; parent must be
 * owned by the attested caller, owner-writable/searchable, not group/other-writable,
 * with ordinary flags and no ACL. This avoids using root rename permission to
 * bypass a source owner's directory restrictions. Does not publish or write.
 * principal_uid must be attested by the trusted transport/kernel, NEVER accepted
 * as an untrusted request value. Both file and parent must belong to that UID:
 * an O_RDWR world-writable victim file alone grants no rename authority.
 * The transport must also attest namespace rights (for example the qualified
 * no-sandbox app). These DAC/ACL checks cannot establish sandbox permissions or
 * peer identity themselves; an IPC caller's UID assertion is not authority.
 * The helper transport must supply the caller's witness, not open one as root.
 * Caller initializes with HG_GUEST_WRITE_AUTHORITY_INIT and retains source. */
int hg_guest_write_authority_open(const HGGuestDisk *source,int incoming_write_fd,uid_t principal_uid,
                                   HGGuestWriteAuthority *authority,const char **error);
int hg_guest_write_authority_unchanged(const HGGuestWriteAuthority *authority);
void hg_guest_write_authority_close(HGGuestWriteAuthority *authority);
#endif
