#include "HGGuestRoles.h"
#include <stdlib.h>
#include <string.h>

static uint16_t neutral(uint16_t role) { return role==1 || role==64 ? 0 : role; }
static int identity(const HGGuestAPFSVolume *a,const HGGuestAPFSVolume *b) {
    return a->oid==b->oid && !memcmp(a->uuid,b->uuid,16) &&
        !memcmp(a->group_uuid,b->group_uuid,16);
}
static int valid(const HGGuestAPFSCatalog *c) {
    if (!c || !c->record_count || c->record_count>HG_APFS_MAX_RECORDS ||
        !c->checkpoint_count || c->checkpoint_count>4097 || !c->latest_checkpoint_xid ||
        c->block_size<4096 || c->block_size>65536 ||
        (c->block_size&(c->block_size-1))) return 0;
    for (uint32_t i=0;i<c->record_count;i++) {
        const HGGuestAPFSRecord *r=&c->records[i];
        unsigned char zero[16]={0};
        if (!r->volume.oid || !r->volume.xid || !r->volume.physical_block ||
            !memcmp(r->volume.uuid,zero,16) || !r->first_checkpoint_xid ||
            r->first_checkpoint_xid>r->last_checkpoint_xid ||
            r->last_checkpoint_xid>c->latest_checkpoint_xid ||
            r->volume.xid>r->first_checkpoint_xid) return 0;
        for (uint32_t j=0;j<i;j++) {
            const HGGuestAPFSRecord *p=&c->records[j];
            if (p->volume.physical_block==r->volume.physical_block) return 0;
            if (p->last_checkpoint_xid==c->latest_checkpoint_xid &&
                r->last_checkpoint_xid==c->latest_checkpoint_xid &&
                (p->volume.oid==r->volume.oid ||
                 !memcmp(p->volume.uuid,r->volume.uuid,16))) return 0;
        }
    }
    return 1;
}

int hg_guest_roles_plan(const HGGuestAPFSCatalog *original,
                        const HGGuestAPFSCatalog *observed,int restore,
                        HGGuestRolePlan **output,const char **error) {
    if (!output || !error) return -1;
    *output=NULL;*error="role-catalog-invalid";
    if ((restore!=0 && restore!=1) || !valid(original) || !valid(observed) ||
        original->block_size!=observed->block_size ||
        observed->latest_checkpoint_xid<original->latest_checkpoint_xid) return -1;
    HGGuestRolePlan *plan=calloc(1,sizeof(*plan));
    if (!plan) { *error="role-plan-allocation";return -1; }
    for (uint32_t i=0;i<observed->record_count;i++) {
        const HGGuestAPFSVolume *v=&observed->records[i].volume;
        const HGGuestAPFSVolume *exact=NULL,*current=NULL;
        for (uint32_t j=0;j<original->record_count;j++) {
            const HGGuestAPFSRecord *r=&original->records[j];
            if (identity(v,&r->volume)) {
                if (v->physical_block==r->volume.physical_block && v->xid==r->volume.xid)
                    exact=&r->volume;
                if (r->last_checkpoint_xid==original->latest_checkpoint_xid)
                    current=&r->volume;
            }
        }
        uint16_t target;
        if (exact) {
            /* Role is the only mutable field admitted for an old record. */
            if (v->flags!=exact->flags ||
                (v->role!=exact->role && (v->role!=neutral(exact->role) || !restore)))
                goto conflict;
            target=restore?exact->role:neutral(exact->role);
        } else {
            /* Checkpoints produced by the mounted copy inherit the neutral role
             * of the current original volume, never an older historical role. */
            if (!restore || !current || v->xid<=original->latest_checkpoint_xid ||
                v->role!=neutral(current->role)) goto conflict;
            target=current->role;
        }
        if (v->role!=target) {
            plan->edits[plan->count].expected=*v;
            plan->edits[plan->count++].target_role=target;
        }
    }
    /* Neutralization must describe exactly the retained original catalog. */
    if (!restore && (original->record_count!=observed->record_count ||
        original->checkpoint_count!=observed->checkpoint_count ||
        original->latest_checkpoint_xid!=observed->latest_checkpoint_xid)) goto conflict;
    *output=plan;*error=NULL;return 0;
conflict:
    free(plan);*error="role-record-conflict";return -1;
}
