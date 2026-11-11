#ifndef HG_GUEST_PAYLOAD_H
#define HG_GUEST_PAYLOAD_H

typedef struct {
    const char *descriptor_sha256;
    const char *compiler_recipe;
    const char *payload_id;
    const char *vlc_core_sha256;
    const char *vlc_reference_lock_sha256;
} HGGuestPayloadIdentity;

/* Read-only verification. Identity comes from constants compiled into the signed
 * helper, never from its command line. Report is malloc-owned UTF-8 JSON. */
int hg_guest_payload_verify_directory(const char *directory,
                                      const HGGuestPayloadIdentity *identity,
                                      char **report);
int hg_guest_payload_verify_executable(const HGGuestPayloadIdentity *identity,
                                       char **report);
#endif
