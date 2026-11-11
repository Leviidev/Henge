#ifndef HG_GUEST_ROLES_H
#define HG_GUEST_ROLES_H
#include "HGGuestAPFS.h"

typedef struct {
    HGGuestAPFSVolume expected;
    uint16_t target_role;
} HGGuestRoleEdit;
typedef struct {
    uint32_t count;
    HGGuestRoleEdit edits[HG_APFS_MAX_RECORDS];
} HGGuestRolePlan;

/* Pure planning only: no file access or rewrite authority. Original must be the
 * strict pre-mutation catalog retained by an owned-clone transaction. Restore
 * accepts historical records by exact identity and new records only by a unique
 * current original volume identity. Caller frees the plan. Failure returns NULL.
 * An executor must independently revalidate checksums, lease, inode, media and
 * expected bytes, persist its recovery journal, and provide write authority. */
int hg_guest_roles_plan(const HGGuestAPFSCatalog *original,
                        const HGGuestAPFSCatalog *observed, int restore,
                        HGGuestRolePlan **plan, const char **error);
#endif
