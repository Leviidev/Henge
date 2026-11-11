/* Henge's first, deliberately read-only root-helper protocol. No disk paths,
 * shell commands or payloads are accepted until provisioning is qualified. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 2 || strcmp(argv[1], "probe-v1") != 0) {
        fputs("unsupported helper operation\n", stderr);
        return 64;
    }
    int root = getuid() == 0 && geteuid() == 0 && getgid() == 0 && getegid() == 0;
    printf("{\"schema\":1,\"operation\":\"probe-v1\",\"root\":%s,"
           "\"uid\":%u,\"euid\":%u,\"gid\":%u,\"egid\":%u,"
           "\"hdik_executable\":%s,\"mount_apfs_executable\":%s,"
           "\"guest_disk_accessed\":false}\n",
           root ? "true" : "false", getuid(), geteuid(), getgid(), getegid(),
           access("/usr/sbin/hdik", X_OK) == 0 ? "true" : "false",
           access("/sbin/mount_apfs", X_OK) == 0 ? "true" : "false");
    return root ? 0 : 77;
}
