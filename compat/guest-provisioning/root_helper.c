/* Read-only identity, payload and inherited-image inspection. No caller paths. */
#include "HGGuestPayload.h"
#include "HGGuestDisk.h"
#include "HGGuestMedia.h"
#include <fcntl.h>
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
    if (argc != 2 || (strcmp(argv[1], "probe-v1") && strcmp(argv[1], "verify-payload-v1") &&
                     strcmp(argv[1], "inspect-image-v1"))) {
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
    if (!strcmp(argv[1], "inspect-image-v1")) {
        if (verified) {
            if (report) puts(report);
            free(report);
            return verified;
        }
        free(report);
        HGGuestDisk disk = {.fd = -1};
        const char *error = "root-required";
        char *media = NULL;
        int media_verified = 0, attached = 0;
        int status = -1;
        if (root) {
            int flags = fcntl(3, F_GETFD);
            if (flags >= 0 && !fcntl(3, F_SETFD, flags | FD_CLOEXEC))
                status = hg_guest_disk_inspect_fd(3, &disk, &error);
            else error = "invalid-descriptor";
        }
        if (!status) {
            status = hg_guest_media_copy(&disk, &media, &error);
            if (!status) {
                media_verified = 1;
                attached = strcmp(media, "[]") != 0;
                if (attached) { error = "image-already-attached"; status = -1; }
            }
        }
        printf("{\"schema\":1,\"operation\":\"inspect-image-v1\",\"root\":%s,"
               "\"uid\":%u,\"euid\":%u,\"gid\":%u,\"egid\":%u,"
               "\"payload_verified\":true,\"image_inspected\":%s,\"error\":\"%s\","
               "\"image_bytes\":%llu,\"partitions\":%u,\"first_apfs_lba\":%llu,"
               "\"last_apfs_lba\":%llu,\"exclusive_lease_verified\":%s,"
               "\"media_inventory_verified\":%s,\"image_modified\":false,"
               "\"image_attached\":%s,\"volume_mounted\":false}\n",
               root ? "true" : "false", getuid(), geteuid(), getgid(), getegid(),
               !status ? "true" : "false", error ? error : "",
               (unsigned long long)disk.identity.st_size, disk.partitions,
               (unsigned long long)disk.first_apfs_lba, (unsigned long long)disk.last_apfs_lba,
               !status ? "true" : "false", media_verified ? "true" : "false", attached ? "true" : "false");
        free(media);
        hg_guest_disk_close(&disk);
        return !root ? 77 : !status ? 0 : (!strcmp(error, "image-in-use") || attached) ? 75 : 65;
    }
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
