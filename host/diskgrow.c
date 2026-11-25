/* hv_disk_grow (hvsparse.h): a bigger disk for a Mac that is already installed. */
#include "hvsparse.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SECTOR 512u
#define ENTRIES 128u
#define ESIZE 128u
#define TABLE (ENTRIES * ESIZE)
#define STEP (8u << 20)

/* As they lie on disk. */
static const uint8_t APFS[16] = {0xEF, 0x57, 0x34, 0x7C, 0x00, 0x00, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC};
static const uint8_t RECOVERY[16] = {0x72, 0x76, 0x63, 0x52, 0x00, 0x79, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC};

static uint32_t crc(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    while (n--) {
        c ^= *p++;
        for (int k = 0; k < 8; k++) c = c >> 1 ^ (0xEDB88320u & -(c & 1));
    }
    return ~c;
}
static uint64_t get64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static uint32_t get32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void put64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

int hv_disk_grow(const char *path, uint64_t new_size, char *err, unsigned long errlen) {
#define FAIL(...) do { snprintf(err, errlen, __VA_ARGS__); goto done; } while (0)
    int fd = open(path, O_RDWR), rc = -1, grew = 0;
    struct stat st;
    uint8_t h[SECTOR], *table = malloc(TABLE), *buf = malloc(STEP);
    uint64_t old = 0;
    if (fd < 0 || fstat(fd, &st) != 0 || !table || !buf) FAIL("The disk could not be opened.");
    old = (uint64_t)st.st_size;
    if (new_size % (1u << 20) || new_size <= old) FAIL("The new size must be bigger than the disk.");
    if (pread(fd, h, SECTOR, SECTOR) != SECTOR || memcmp(h, "EFI PART", 8)) FAIL("The disk has no GUID partition table.");
    uint32_t hlen = get32(h + 12), want = get32(h + 16);
    if (hlen < 92 || hlen > SECTOR) FAIL("The partition table's header is not understood.");
    put32(h + 16, 0);
    if (crc(h, hlen) != want) FAIL("The partition table's header is damaged.");
    if (get64(h + 72) != 2 || get32(h + 80) != ENTRIES || get32(h + 84) != ESIZE) FAIL("The partition table is not laid out as macOS's.");
    if (pread(fd, table, TABLE, 2 * SECTOR) != (ssize_t)TABLE || crc(table, TABLE) != get32(h + 88)) FAIL("The partition table is damaged.");
    uint8_t *main_p = NULL, *rec = NULL;
    uint64_t top = 0;
    for (unsigned i = 0; i < ENTRIES; i++) {
        uint8_t *e = table + i * ESIZE;
        static const uint8_t none[16];
        if (!memcmp(e, none, 16)) continue;
        uint64_t last = get64(e + 40);
        if (get64(e + 32) > last || (last + 1) * SECTOR > old) FAIL("A partition lies outside the disk.");
        if (last > top) top = last;
        if (!memcmp(e, APFS, 16)) {
            if (main_p) FAIL("There is more than one main partition.");
            main_p = e;
        }
        if (!memcmp(e, RECOVERY, 16)) {
            if (rec) FAIL("There is more than one Recovery partition.");
            rec = e;
        }
    }
    if (!main_p) FAIL("The main partition was not found.");
    uint64_t main_first = get64(main_p + 32), main_last = get64(main_p + 40);
    uint64_t sectors = new_size / SECTOR, usable = sectors - 34; /* the last one a partition may use */
    uint64_t new_last = usable & ~7ull; /* 4 KB aligned, exclusive */
    uint64_t rfirst = 0, rlen = 0, rnew = 0;
    if (rec) {
        rfirst = get64(rec + 32), rlen = get64(rec + 40) - rfirst + 1;
        if (get64(rec + 40) != top || rfirst < main_last) FAIL("Recovery is not the last partition.");
        rnew = (new_last - rlen) & ~7ull;
        if (rnew < rfirst + rlen) FAIL("The new size must be at least %llu GB bigger.", (unsigned long long)(rlen * SECTOR / 1000000000 + 2));
    } else if (main_last != top) FAIL("The main partition is not the last.");
    /* Nothing may lie between the main partition and Recovery. */
    for (unsigned i = 0; i < ENTRIES; i++) {
        uint8_t *e = table + i * ESIZE;
        if (e != main_p && e != rec && get64(e + 40) > main_first && get64(e + 32) < (rec ? rfirst : sectors) && get64(e + 40)) FAIL("Another partition follows the main one.");
    }
    if (ftruncate(fd, (off_t)new_size) != 0) FAIL("The disk could not be made bigger: %s", strerror(errno));
    grew = 1;
    /* Recovery's copy first (its old place stays whole until the table says otherwise); holes stay holes. */
    for (uint64_t at = 0; at < rlen * SECTOR;) {
        size_t n = rlen * SECTOR - at < STEP ? (size_t)(rlen * SECTOR - at) : STEP;
        if (pread(fd, buf, n, (off_t)(rfirst * SECTOR + at)) != (ssize_t)n) FAIL("Reading Recovery failed: %s", strerror(errno));
        size_t z = 0;
        while (z < n && !buf[z]) z++;
        if (z < n && pwrite(fd, buf, n, (off_t)(rnew * SECTOR + at)) != (ssize_t)n) FAIL("Writing Recovery failed: %s", strerror(errno));
        at += n;
    }
    if (fsync(fd) != 0) FAIL("Writing failed: %s", strerror(errno));
    if (rec) put64(rec + 32, rnew), put64(rec + 40, rnew + rlen - 1);
    put64(main_p + 40, (rec ? rnew : new_last) - 1);
    uint32_t tcrc = crc(table, TABLE);
    uint8_t back[SECTOR];
    put64(h + 48, usable);
    put32(h + 88, tcrc);
    memcpy(back, h, SECTOR);
    put64(h + 24, 1), put64(h + 32, sectors - 1);
    put64(back + 24, sectors - 1), put64(back + 32, 1), put64(back + 72, sectors - 33);
    put32(h + 16, crc(h, hlen)), put32(back + 16, crc(back, hlen));
    /* The backup at the new end first, then the primary's entries and header, 16.5 KB together. */
    if (pwrite(fd, table, TABLE, (off_t)((sectors - 33) * SECTOR)) != (ssize_t)TABLE ||
        pwrite(fd, back, SECTOR, (off_t)((sectors - 1) * SECTOR)) != SECTOR || fsync(fd) != 0) FAIL("Writing the partition table failed: %s", strerror(errno));
    /* The protective MBR's size, when it has room to say it. */
    uint8_t mbr[SECTOR], head[2 * SECTOR + TABLE];
    if (pread(fd, mbr, SECTOR, 0) != SECTOR) FAIL("Reading failed: %s", strerror(errno));
    if (mbr[446 + 4] == 0xEE) put32(mbr + 446 + 12, sectors - 1 > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)(sectors - 1));
    memcpy(head, mbr, SECTOR), memcpy(head + SECTOR, h, SECTOR), memcpy(head + 2 * SECTOR, table, TABLE);
    if (pwrite(fd, head, sizeof head, 0) != (ssize_t)sizeof head || fsync(fd) != 0) {
        snprintf(err, errlen, "Writing the partition table failed: %s", strerror(errno));
        grew = 0; /* the new table may be half there: the backup at the new end is whole, so the file stays as it is */
        goto done;
    }
    rc = 0;
done:
    if (rc != 0 && grew) ftruncate(fd, (off_t)old);
    free(table), free(buf);
    if (fd >= 0) close(fd);
    return rc;
#undef FAIL
}
