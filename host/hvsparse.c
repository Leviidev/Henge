#include "hvsparse.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __APPLE__
#include <compression.h>
#include <dispatch/dispatch.h>
#include <zlib.h>
#endif

#define CHUNK (8u << 20)

static int write_all(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t w = write(fd, b, n);
        if (w <= 0) return -1;
        b += w, n -= (size_t)w;
    }
    return 0;
}

static int read_all(int fd, void *p, size_t n) {
    uint8_t *b = p;
    while (n) {
        ssize_t r = read(fd, b, n);
        if (r <= 0) return -1;
        b += r, n -= (size_t)r;
    }
    return 0;
}

static int all_zero(const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (p[i]) return 0;
    return 1;
}

/* Check the opened files, since different paths can name the same disk image. */
static int open_output(const char *path, const struct stat *input) {
    int fd = open(path, O_WRONLY | O_CREAT, 0644);
    if (fd < 0) return -1;
    struct stat output;
    if (fstat(fd, &output) != 0 ||
        (output.st_dev == input->st_dev && output.st_ino == input->st_ino) ||
        ftruncate(fd, 0) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int hv_sparse_pack_progress(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    int in = open(src, O_RDONLY), out = -1;
    struct stat st;
    uint8_t *buf = malloc(CHUNK);
    int rc = -1;
    if (in < 0 || fstat(in, &st) != 0 || !buf) goto done;
    out = open_output(dst, &st);
    if (out < 0) goto done;
    uint64_t size = (uint64_t)st.st_size;
    if (write_all(out, "HVSPARSE", 8) || write_all(out, &size, 8)) goto done;
    /* Walk the data runs (SEEK_DATA/SEEK_HOLE), and skip zero chunks inside them too. */
    off_t pos = 0;
    while ((uint64_t)pos < size) {
        off_t data = lseek(in, pos, SEEK_DATA);
        if (data < 0) break; /* no more data */
        off_t hole = lseek(in, data, SEEK_HOLE);
        if (hole < 0) hole = (off_t)size;
        for (off_t at = data; at < hole;) {
            size_t n = (size_t)(hole - at < CHUNK ? hole - at : CHUNK);
            if (pread(in, buf, n, at) != (ssize_t)n) goto done;
            if (!all_zero(buf, n)) {
                uint64_t rec[2] = {(uint64_t)at, n};
                if (write_all(out, rec, 16) || write_all(out, buf, n)) goto done;
            }
            at += (off_t)n;
            if (progress) progress((uint64_t)at, size, opaque);
        }
        pos = hole;
    }
    uint64_t end[2] = {0, 0};
    if (write_all(out, end, 16)) goto done;
    if (fsync(out) != 0) goto done;
    rc = 0;
done:
    free(buf);
    if (in >= 0) close(in);
    if (out >= 0 && close(out) != 0) rc = -1;
    return rc;
}

int hv_sparse_pack(const char *src, const char *dst) { return hv_sparse_pack_progress(src, dst, NULL, NULL); }

static int unpack_plain(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    int in = open(src, O_RDONLY), out = -1;
    struct stat st;
    uint8_t *buf = malloc(CHUNK);
    int rc = -1;
    char magic[8];
    uint64_t size;
    if (in < 0 || fstat(in, &st) != 0 || !buf || read_all(in, magic, 8) || memcmp(magic, "HVSPARSE", 8) || read_all(in, &size, 8)) goto done;
    out = open_output(dst, &st);
    if (out < 0) goto done;
    if (ftruncate(out, (off_t)size) != 0) goto done; /* the holes stay holes */
    for (;;) {
        uint64_t rec[2];
        if (read_all(in, rec, 16)) goto done;
        if (!rec[1]) break;
        if (rec[1] > CHUNK || rec[0] + rec[1] > size) goto done;
        if (read_all(in, buf, rec[1]) || pwrite(out, buf, rec[1], (off_t)rec[0]) != (ssize_t)rec[1]) goto done;
        if (progress) progress(rec[0] + rec[1], size, opaque);
    }
    rc = fsync(out);
done:
    free(buf);
    if (in >= 0) close(in);
    if (out >= 0 && close(out) != 0) rc = -1;
    return rc;
}

#ifdef __APPLE__
#define ZCHUNK (4u << 20)
#define ZBATCH 16
typedef struct { uint64_t off; uint32_t len, packed, crc, zero; } ZRec;
typedef struct { ZRec r; uint8_t *raw, *pack; int bad; } ZSlot;

static int slots_open(ZSlot *s) {
    memset(s, 0, sizeof *s * ZBATCH);
    for (int i = 0; i < ZBATCH; i++)
        if (!(s[i].raw = malloc(ZCHUNK)) || !(s[i].pack = malloc(ZCHUNK))) return -1;
    return 0;
}
static void slots_close(ZSlot *s) {
    for (int i = 0; i < ZBATCH; i++) free(s[i].raw), free(s[i].pack);
}

static int flush_packed(int out, ZSlot *s, int n, uint64_t *count) {
    dispatch_apply((size_t)n, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        ZSlot *z = &s[i];
        z->r.crc = (uint32_t)crc32(0, z->raw, z->r.len);
        size_t c = compression_encode_buffer(z->pack, z->r.len - 1, z->raw, z->r.len, NULL, COMPRESSION_LZFSE);
        z->r.packed = c ? (uint32_t)c : z->r.len;
    });
    for (int i = 0; i < n; i++) {
        if (write_all(out, &s[i].r, sizeof s[i].r)) return -1;
        if (write_all(out, s[i].r.packed == s[i].r.len ? s[i].raw : s[i].pack, s[i].r.packed)) return -1;
    }
    *count += (uint64_t)n;
    return 0;
}

int hv_sparse_pack_compressed(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    int in = open(src, O_RDONLY), out = -1, rc = -1, n = 0;
    struct stat st;
    ZSlot s[ZBATCH];
    uint64_t count = 0;
    int ok = slots_open(s) == 0;
    if (!ok || in < 0 || fstat(in, &st) != 0) goto done;
    out = open_output(dst, &st);
    if (out < 0) goto done;
    uint64_t size = (uint64_t)st.st_size;
    if (write_all(out, "HVSPARZ1", 8) || write_all(out, &size, 8)) goto done;
    off_t pos = 0;
    while ((uint64_t)pos < size) {
        off_t data = lseek(in, pos, SEEK_DATA);
        if (data < 0) {
            if (errno != ENXIO) goto done; /* ENXIO: nothing but a hole is left */
            break;
        }
        off_t hole = lseek(in, data, SEEK_HOLE);
        if (hole < 0) hole = (off_t)size;
        for (off_t at = data; at < hole;) {
            size_t len = (size_t)(hole - at < ZCHUNK ? hole - at : ZCHUNK);
            if (pread(in, s[n].raw, len, at) != (ssize_t)len) goto done;
            if (!all_zero(s[n].raw, len)) {
                s[n].r = (ZRec){.off = (uint64_t)at, .len = (uint32_t)len};
                if (++n == ZBATCH) {
                    if (flush_packed(out, s, n, &count)) goto done;
                    n = 0;
                    if (progress) progress((uint64_t)at, size, opaque);
                }
            }
            at += (off_t)len;
        }
        pos = hole;
    }
    if (n && flush_packed(out, s, n, &count)) goto done;
    ZRec end = {.off = count};
    if (write_all(out, &end, sizeof end) || fsync(out) != 0) goto done;
    if (progress) progress(size, size, opaque);
    rc = 0;
done:
    slots_close(s);
    if (in >= 0) close(in);
    if (out >= 0 && close(out) != 0) rc = -1;
    return rc;
}

/* Reads a compressed file after its magic; out < 0: only checks it. */
static int read_compressed(int in, int out, uint64_t size, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    ZSlot s[ZBATCH];
    uint64_t count = 0;
    int rc = -1, more = 1;
    if (slots_open(s)) goto done;
    while (more) {
        int n = 0;
        while (n < ZBATCH) {
            ZRec *r = &s[n].r;
            if (read_all(in, r, sizeof *r)) goto done; /* cut short */
            if (!r->len) {
                if (r->off != count + (uint64_t)n) goto done;
                more = 0;
                break;
            }
            if (r->len > ZCHUNK || !r->packed || r->packed > r->len || r->off > size || r->len > size - r->off) goto done;
            if (read_all(in, r->packed == r->len ? s[n].raw : s[n].pack, r->packed)) goto done;
            s[n++].bad = 0;
        }
        ZSlot *z = s;
        dispatch_apply((size_t)n, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            ZRec *r = &z[i].r;
            if (r->packed != r->len && compression_decode_buffer(z[i].raw, r->len, z[i].pack, r->packed, NULL, COMPRESSION_LZFSE) != r->len) z[i].bad = 1;
            else if ((uint32_t)crc32(0, z[i].raw, r->len) != r->crc) z[i].bad = 1;
        });
        for (int i = 0; i < n; i++)
            if (s[i].bad || (out >= 0 && pwrite(out, s[i].raw, s[i].r.len, (off_t)s[i].r.off) != (ssize_t)s[i].r.len)) goto done;
        count += (uint64_t)n;
        if (n && progress) progress(s[n - 1].r.off + s[n - 1].r.len, size, opaque);
    }
    rc = 0;
done:
    slots_close(s);
    return rc;
}

static int unpack_compressed(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    int in = open(src, O_RDONLY), out = -1, rc = -1;
    struct stat st;
    char magic[8];
    uint64_t size;
    if (in < 0 || fstat(in, &st) != 0 || read_all(in, magic, 8) || read_all(in, &size, 8)) goto done;
    if (!dst) {
        rc = read_compressed(in, -1, size, progress, opaque);
        goto done;
    }
    out = open_output(dst, &st);
    if (out < 0 || ftruncate(out, (off_t)size) != 0) goto done;
    rc = read_compressed(in, out, size, progress, opaque);
    if (rc == 0) rc = fsync(out);
done:
    if (in >= 0) close(in);
    if (out >= 0 && close(out) != 0) rc = -1;
    return rc;
}
#else
int hv_sparse_pack_compressed(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    (void)src, (void)dst, (void)progress, (void)opaque;
    return -1;
}
static int unpack_compressed(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    (void)src, (void)dst, (void)progress, (void)opaque;
    return -1;
}
#endif

/* Whether it is a compressed one. */
static int compressed(const char *src) {
    char magic[8];
    int fd = open(src, O_RDONLY), yes = fd >= 0 && read_all(fd, magic, 8) == 0 && !memcmp(magic, "HVSPARZ1", 8);
    if (fd >= 0) close(fd);
    return yes;
}

int hv_sparse_unpack(const char *src, const char *dst, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    return compressed(src) ? unpack_compressed(src, dst, progress, opaque) : unpack_plain(src, dst, progress, opaque);
}

int hv_sparse_verify(const char *src, void (*progress)(uint64_t, uint64_t, void *), void *opaque) {
    return compressed(src) ? unpack_compressed(src, NULL, progress, opaque) : -1;
}
