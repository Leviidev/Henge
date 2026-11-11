#ifndef HG_GUEST_PEER_H
#define HG_GUEST_PEER_H
#include <sys/types.h>
#include <stdint.h>

typedef struct {
    pid_t pid;
    uid_t uid;
    int64_t start_seconds, start_microseconds;
    unsigned char cdhash[20];
    int verified;
} HGGuestPeer;
/* Qualify the actual live parent, never a caller-supplied PID/UID. The trusted
 * helper opens its own bundle's main executable read-only and passes that FD.
 * Kernel credentials/start time/path/CDHash are sampled before and after; the
 * held executable's CodeDirectory and every covered page must match. Kernel
 * entitlements must explicitly contain Boolean no-sandbox=true. These checks
 * qualify the main executable, not external resources or loaded dependencies.
 * Per-target sandbox policy and DAC/ACL/write-witness checks remain separate.
 * Caller must use the output only on success. Failure clears all output. */
int hg_guest_peer_attest(int expected_executable_fd,HGGuestPeer *peer,const char **error);
int hg_guest_peer_unchanged(int expected_executable_fd,const HGGuestPeer *peer,const char **error);
#endif
