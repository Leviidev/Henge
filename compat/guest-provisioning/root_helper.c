/* Read-only identity/payload checks. No caller paths or guest disk operations. */
#include "HGGuestPayload.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef HG_PAYLOAD_DESCRIPTOR_SHA
#define HG_PAYLOAD_DESCRIPTOR_SHA ""
#define HG_PAYLOAD_RECIPE ""
#define HG_PAYLOAD_ID ""
#define HG_PAYLOAD_VLC_CORE ""
#define HG_PAYLOAD_VLC_LOCK ""
#endif
static const HGGuestPayloadIdentity payload_identity = {
    HG_PAYLOAD_DESCRIPTOR_SHA, HG_PAYLOAD_RECIPE, HG_PAYLOAD_ID,
    HG_PAYLOAD_VLC_CORE, HG_PAYLOAD_VLC_LOCK
};

int main(int argc, char **argv)
{
    if (argc != 2 || (strcmp(argv[1], "probe-v1") && strcmp(argv[1], "verify-payload-v1"))) {
        fputs("unsupported helper operation\n", stderr);
        return 64;
    }
    char *report = NULL;
    int verified = hg_guest_payload_verify_executable(&payload_identity, &report);
    if (!strcmp(argv[1], "verify-payload-v1")) {
        if (report) puts(report);
        free(report);
        return verified;
    }
    int root = getuid() == 0 && geteuid() == 0 && getgid() == 0 && getegid() == 0;
    printf("{\"schema\":1,\"operation\":\"probe-v1\",\"root\":%s,"
           "\"uid\":%u,\"euid\":%u,\"gid\":%u,\"egid\":%u,"
           "\"hdik_executable\":%s,\"mount_apfs_executable\":%s,"
           "\"payload_verified\":%s,\"payload_verification\":%s,\"guest_disk_accessed\":false}\n",
           root ? "true" : "false", getuid(), geteuid(), getgid(), getegid(),
           access("/usr/sbin/hdik", X_OK) == 0 ? "true" : "false",
           access("/sbin/mount_apfs", X_OK) == 0 ? "true" : "false",
           verified == 0 ? "true" : "false", report ? report : "null");
    free(report);
    return root ? 0 : 77;
}
