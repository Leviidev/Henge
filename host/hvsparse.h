#ifndef HENGEVM_HVSPARSE_H
#define HENGEVM_HVSPARSE_H

#include <stdint.h>

/* A disk image with its holes left out, for moving one to an iPhone: Finder's
   file sharing copies every byte of a sparse file, holes included.
     "HVSPARSE" magic, u64 logical size, then records {u64 offset, u64 length, data}
     until a record with length 0. Little-endian. */

/* Packed and compressed (a backup): "HVSPARZ1", u64 logical size, then records {u64 offset, u32 length, u32 packed
   length, u32 CRC-32 of the data, u32 0, packed data} (LZFSE; stored as it is when that is no smaller), until a record
   with length 0 whose offset is the number of records before it. Where Apple's compression isn't (Linux) these return -1. */
int hv_sparse_pack_compressed(const char *src, const char *dst, void (*progress)(uint64_t done, uint64_t total, void *opaque), void *opaque);
/* Reads a whole packed file of either kind, checking it, without writing anything. Returns 0 or -1. */
int hv_sparse_verify(const char *src, void (*progress)(uint64_t done, uint64_t total, void *opaque), void *opaque);

/* Make a Mac's disk image bigger: the Recovery partition (the last) moves to the new end, and the main APFS partition
   takes the room up to it. macOS still has to grow its container: diskutil apfs resizeContainer disk0s2 0. The image
   must not be in use. Returns 0, or -1 with the reason in err; nothing is changed when it returns before writing the
   partition table, which is the last thing it does. */
int hv_disk_grow(const char *path, uint64_t new_size, char *err, unsigned long errlen);

/* Pack src (a sparse raw image) into dst. Returns 0 or -1. */
int hv_sparse_pack(const char *src, const char *dst);
/* The same; progress(position, size, opaque) may be NULL. */
int hv_sparse_pack_progress(const char *src, const char *dst, void (*progress)(uint64_t done, uint64_t total, void *opaque), void *opaque);
/* Both: unpack into a sparse file. progress(done, total, opaque) may be NULL. Returns 0 or -1. */
int hv_sparse_unpack(const char *src, const char *dst, void (*progress)(uint64_t done, uint64_t total, void *opaque), void *opaque);

#endif
