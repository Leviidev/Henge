#ifndef HG_GUEST_WORKSPACE_H
#define HG_GUEST_WORKSPACE_H
#include "HGGuestDisk.h"

typedef struct {
    int parent_fd, directory_fd;
    char name[64];
    struct stat directory_identity;
    HGGuestDisk source_identity; /* Receipt metadata only; never opens source. */
    int cleared, removed;
} HGGuestWorkspace;
#define HG_GUEST_WORKSPACE_INIT { .parent_fd=-1, .directory_fd=-1, .source_identity={.fd=-1} }

/* Parent is a trusted private directory owned by effective UID, with no
 * group/other access and no extended ACL. All contents are exclusively
 * helper-managed; this namespace trust is required for cleanup of files whose
 * creator died before recording their individual inode. Creation
 * syncs an inode-bound ownership receipt BEFORE returning a usable workspace.
 * Caller retains the source lease. No caller/source paths are persisted. */
int hg_guest_workspace_create(int private_parent_fd,const HGGuestDisk *source,
                               HGGuestWorkspace *workspace,const char **error);
/* Reopen a named workspace after process death. Acquires its exclusive lease,
 * verifies private ownership and the durable receipt's directory identity.
 * Unknown/unreceipted directories are preserved, not guessed to be ours. */
int hg_guest_workspace_open(int private_parent_fd,const char *name,
                             HGGuestWorkspace *workspace,const char **error);
/* Discard-only recovery, never replay/mount/publish. Preflights a closed bounded
 * namespace of at most one private clone and its role journals; rejects unknown
 * entries, links, source inode, replacement paths and busy/unavailable media.
 * Leases all files and verifies empty clone media before unlinking anything.
 * Successful cleanup syncs the workspace and parent. Failure retains state for
 * retry. This is ONLY for unpublished, helper-private copies. */
int hg_guest_workspace_discard(HGGuestWorkspace *workspace,const char **error);
/* Releases descriptors/leases without deleting files. */
void hg_guest_workspace_close(HGGuestWorkspace *workspace);
#endif
