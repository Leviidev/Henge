#include <fcntl.h>
#include <errno.h>
#include "../core/machine.h"
#include "disk.h"

#include <sys/stat.h>
#include <sys/file.h>
#include <stdlib.h>
#include <unistd.h>

#define DISK_IO_CHUNK (128u << 20)

int hv_disk_open(HvDisk *d, const char *path, uint64_t offset, int readonly) {
    d->wfd = -1;
    d->fd = open(path, readonly ? O_RDONLY : O_RDWR);
    if (d->fd < 0) return -1;
    if(flock(d->fd,(readonly ? LOCK_SH : LOCK_EX)|LOCK_NB)){close(d->fd);d->fd=-1;return -1;}
    struct stat st;
    if (fstat(d->fd, &st) != 0 || (uint64_t)st.st_size < offset) {
        close(d->fd);
        d->fd = -1;
        return -1;
    }
    d->offset = offset;
    d->size = (uint64_t)st.st_size - offset;
    d->readonly = readonly;
    /* HV_WRITE_CACHE=0: writes skip the host's cache (F_NOCACHE), so a long run of them cannot pile up
       gigabytes of dirty pages; reads stay cached, and the kernel keeps the two coherent. Off by default:
       on the Mac bench big writes took 2-3x as long that way (2 GB + sync 4-6 s -> 9-17 s) and everyday
       work was no faster. The phone's installer turns it on for the restore, which writes ~15 GB at once. */
    const char *wc = getenv("HV_WRITE_CACHE");
    if (!readonly && wc && !atoi(wc)) {
        d->wfd = open(path, O_RDWR);
        if (d->wfd >= 0 && fcntl(d->wfd, F_NOCACHE, 1) == -1) {
            close(d->wfd);
            d->wfd = -1;
        }
    }
    return 0;
}

void hv_disk_close(HvDisk *d) {
    if (d->fd >= 0) close(d->fd);
    if (d->wfd >= 0) close(d->wfd);
    d->fd = d->wfd = -1;
}

int hv_disk_read(HvDisk *d, uint64_t off, void *buf, uint64_t len) {
    if (off > d->size || len > d->size - off) return -1;
    uint8_t *p = buf;
    while (len) {
        size_t count = len > DISK_IO_CHUNK ? DISK_IO_CHUNK : (size_t)len;
        ssize_t n = pread(d->fd, p, count, (off_t)(d->offset + off));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        off += (uint64_t)n;
        len -= (uint64_t)n;
    }
    return 0;
}

int hv_disk_write(HvDisk *d, uint64_t off, const void *buf, uint64_t len) {
    if (d->readonly || off > d->size || len > d->size - off) return -1;
    const uint8_t *p = buf;
    while (len) {
        size_t count = len > DISK_IO_CHUNK ? DISK_IO_CHUNK : (size_t)len;
        ssize_t n = pwrite(d->wfd >= 0 ? d->wfd : d->fd, p, count, (off_t)(d->offset + off));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        off += (uint64_t)n;
        len -= (uint64_t)n;
    }
    return 0;
}

/* A short vectored transfer can end inside any vector. Build each syscall's
   bounded slice from the immutable caller array; advance only by bytes the
   kernel actually transferred. EINTR never advances that cursor. */
static int disk_iov(HvDisk *d, uint64_t off, const struct iovec *iov, int count, int writing) {
    if (count < 0 || count > HV_DISK_IOV_MAX || (count && !iov) || (writing && d->readonly)) return -1;
    uint64_t total = 0;
    for (int i = 0; i < count; i++) {
        if ((iov[i].iov_len && !iov[i].iov_base) || iov[i].iov_len > UINT64_MAX - total) return -1;
        total += iov[i].iov_len;
    }
    if (off > d->size || total > d->size - off || d->offset > INT64_MAX || off > INT64_MAX - d->offset ||
        total > (uint64_t)INT64_MAX - d->offset - off) return -1;
    int index = 0;
    size_t skip = 0;
    while (total) {
        struct iovec part[HV_DISK_IOV_MAX];
        size_t requested = 0;
        int nvec = 0;
        for (int i = index; i < count && requested < DISK_IO_CHUNK; i++) {
            size_t begin = i == index ? skip : 0;
            size_t size = iov[i].iov_len - begin;
            if (!size) continue;
            if (size > DISK_IO_CHUNK - requested) size = DISK_IO_CHUNK - requested;
            part[nvec++] = (struct iovec){(uint8_t *)iov[i].iov_base + begin, size};
            requested += size;
        }
        ssize_t n = writing ? pwritev(d->wfd >= 0 ? d->wfd : d->fd, part, nvec, (off_t)(d->offset + off)) :
                              preadv(d->fd, part, nvec, (off_t)(d->offset + off));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0 || (uint64_t)n > requested) return -1;
        off += (uint64_t)n;
        total -= (uint64_t)n;
        size_t advanced = (size_t)n;
        while (index < count) {
            size_t left = iov[index].iov_len - skip;
            if (advanced < left) { skip += advanced; break; }
            advanced -= left; index++; skip = 0;
        }
    }
    return 0;
}
int hv_disk_readv(HvDisk *d, uint64_t off, const struct iovec *iov, int count) {
    return disk_iov(d, off, iov, count, 0);
}
int hv_disk_writev(HvDisk *d, uint64_t off, const struct iovec *iov, int count) {
    return disk_iov(d, off, iov, count, 1);
}

/* HV_FLUSH: 0 fsync; 1 nothing here, what was written is safe in the host's cache as long as the
   host runs; 2 fcntl(F_BARRIERFSYNC). */
int hv_disk_flush(HvDisk *d) {
    if (d->readonly) return 0;
    switch (hv_knob[HV_K_FLUSH]) {
    case 1: return 0;
    case 2: return fcntl(d->fd, F_BARRIERFSYNC) == -1 ? -1 : 0;
    default: return fsync(d->fd);
    }
}
