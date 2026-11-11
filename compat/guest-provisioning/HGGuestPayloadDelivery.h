#ifndef HG_GUEST_PAYLOAD_DELIVERY_H
#define HG_GUEST_PAYLOAD_DELIVERY_H
#include "HGGuestPayload.h"
/* Deliver a verified, versioned payload into the fixed Library/Application
 * Support/Henge/Compatibility tree of an already validated PRIVATE-COPY Data
 * volume root. Caller retains exclusive image/mount ownership and must separately
 * establish writable Data-volume identity, OS compatibility and safe detach.
 * This API establishes NONE of those authorities. Never pass an active/original
 * guest root. It confines openat paths to same-device, caller-owned ordinary
 * directories with no extended ACL or external write access. New directories
 * are 0755; existing directory metadata and conflicting versions are preserved.
 * Payload integrity is checked BEFORE any tree creation and after staging.
 * No activation, current-version selector, app mutation or image publication is
 * performed. Returned report is malloc-owned JSON; success is delivery only. */
int hg_guest_payload_deliver_data_root(const char *resources,
    const HGGuestPayloadIdentity *identity,int trusted_private_data_root_fd,char **report);
#endif
