#include "HGGuestDisk.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>
#include <zlib.h>

static uint32_t u32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t u64(const unsigned char *p) {
    return (uint64_t)u32(p) | (uint64_t)u32(p + 4) << 32;
}
static int nonzero(const unsigned char *p, size_t length) {
    for (size_t i = 0; i < length; ++i) if (p[i]) return 1;
    return 0;
}
static int read_at(int fd, void *buffer, size_t count, uint64_t offset) {
    size_t used = 0;
    while (used < count) {
        ssize_t n = pread(fd, (char *)buffer + used, count - used, (off_t)(offset + used));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        used += (size_t)n;
    }
    return 0;
}
static int same(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}
int hg_guest_disk_unchanged(const HGGuestDisk *disk) {
    struct stat current;
    return disk && disk->fd >= 0 && !fstat(disk->fd, &current) && same(&disk->identity, &current);
}
void hg_guest_disk_close(HGGuestDisk *disk) {
    if (disk && disk->fd >= 0) { close(disk->fd); disk->fd = -1; }
}

static int header(unsigned char h[512], uint64_t own, uint64_t other, uint64_t sectors) {
    if (memcmp(h, "EFI PART", 8) || u32(h + 8) != 0x00010000 ||
        u32(h + 12) < 92 || u32(h + 12) > 512 || u32(h + 20) ||
        u64(h + 24) != own || u64(h + 32) != other || !nonzero(h + 56, 16)) return -1;
    uint32_t expected = u32(h + 16);
    memset(h + 16, 0, 4);
    uint32_t actual = (uint32_t)crc32(0, h, u32(h + 12));
    h[16] = expected; h[17] = expected >> 8; h[18] = expected >> 16; h[19] = expected >> 24;
    uint32_t count = u32(h + 80), size = u32(h + 84);
    if (actual != expected || !count || count > 128 || size < 128 || size > 1024 || (size & (size - 1)))
        return -1;
    uint64_t table_sectors = ((uint64_t)count * size + 511) / 512;
    uint64_t table = u64(h + 72), first = u64(h + 40), last = u64(h + 48);
    if (first > last || first < 2 || last >= sectors - 1 || table < 2 ||
        table >= sectors - 1 || table_sectors > sectors - 1 - table) return -1;
    if (own == 1 ? table + table_sectors > first : table <= last) return -1;
    return 0;
}

int hg_guest_disk_inspect_fd(int incoming, HGGuestDisk *disk, const char **error) {
    if (!disk || !error) { errno = EINVAL; return -1; }
    memset(disk, 0, sizeof(*disk)); disk->fd = -1;
    *error = "invalid-descriptor";
    int flags = fcntl(incoming, F_GETFL);
    struct stat source;
    if (flags < 0 || (flags & O_ACCMODE) != O_RDONLY || fstat(incoming, &source) ||
        !S_ISREG(source.st_mode) || source.st_size < 65536 || source.st_size % 512) {
        errno = EINVAL; return -1;
    }
    char path[PATH_MAX];
    memset(path, 0, sizeof(path));
    if (fcntl(incoming, F_GETPATH, path) || !memchr(path, 0, sizeof(path))) return -1;
    disk->fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (disk->fd < 0) return -1;
    *error = "image-identity-changed";
    if (fstat(disk->fd, &disk->identity)) goto fail;
    if (!same(&source, &disk->identity)) { errno = ESTALE; goto fail; }
    *error = "image-in-use";
    if (flock(disk->fd, LOCK_EX | LOCK_NB)) goto fail;
    *error = "invalid-gpt";
    errno = EINVAL;
    unsigned char mbr[512], primary[512], backup[512];
    uint64_t sectors = (uint64_t)source.st_size / 512;
    if (read_at(disk->fd, mbr, 512, 0) || mbr[510] != 0x55 || mbr[511] != 0xaa) goto fail;
    int protective = 0;
    for (int i = 0; i < 4; ++i) if (mbr[446 + i * 16 + 4] == 0xee) protective = 1;
    if (!protective || read_at(disk->fd, primary, 512, 512) ||
        read_at(disk->fd, backup, 512, (sectors - 1) * 512) ||
        header(primary, 1, sectors - 1, sectors) || header(backup, sectors - 1, 1, sectors) ||
        memcmp(primary + 40, backup + 40, 32) || memcmp(primary + 80, backup + 80, 12)) goto fail;
    uint32_t count = u32(primary + 80), size = u32(primary + 84);
    size_t bytes = (size_t)count * size;
    unsigned char *table = malloc(bytes), *mirror = malloc(bytes);
    if (!table || !mirror) { free(table); free(mirror); errno = ENOMEM; goto fail; }
    int valid = !read_at(disk->fd, table, bytes, u64(primary + 72) * 512) &&
        !read_at(disk->fd, mirror, bytes, u64(backup + 72) * 512) &&
        (uint32_t)crc32(0, table, (uInt)bytes) == u32(primary + 88) && !memcmp(table, mirror, bytes);
    static const unsigned char apfs[16] = {0xef,0x57,0x34,0x7c,0,0,0xaa,0x11,0xaa,0x11,0,0x30,0x65,0x43,0xec,0xac};
    uint64_t starts[128], ends[128];
    unsigned char uuids[128][16];
    uint32_t used = 0, apfs_count = 0;
    for (uint32_t i = 0; valid && i < count; ++i) {
        const unsigned char *entry = table + (size_t)i * size;
        /* A zero type GUID marks an unused slot; other bytes may be stale. */
        if (!nonzero(entry, 16)) continue;
        uint64_t first = u64(entry + 32), last = u64(entry + 40);
        if (!nonzero(entry + 16, 16) || first > last || first < u64(primary + 40) || last > u64(primary + 48)) {
            valid = 0; break;
        }
        for (uint32_t j = 0; j < used; ++j)
            if (!(last < starts[j] || first > ends[j]) || !memcmp(uuids[j], entry + 16, 16)) valid = 0;
        memcpy(uuids[used], entry + 16, 16);
        starts[used] = first; ends[used++] = last;
        if (!memcmp(entry, apfs, 16)) {
            ++apfs_count; disk->first_apfs_lba = first; disk->last_apfs_lba = last;
        }
    }
    free(table); free(mirror);
    if (!valid) goto fail;
    *error = "unsupported-apfs-partition-count";
    if (apfs_count != 1) { errno = ENOTSUP; goto fail; }
    disk->partitions = used;
    memcpy(disk->disk_uuid, primary + 56, 16);
    *error = "image-identity-changed";
    if (!hg_guest_disk_unchanged(disk)) { errno = ESTALE; goto fail; }
    *error = NULL;
    return 0;
fail: {
    int saved = errno;
    hg_guest_disk_close(disk);
    errno = saved ? saved : EINVAL;
    return -1;
}
}
