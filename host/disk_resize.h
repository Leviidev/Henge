#ifndef HENGE_DISK_RESIZE_H
#define HENGE_DISK_RESIZE_H
#include <stddef.h>
#include <stdint.h>
/* Offline raw GPT image expansion. Clone, repair both GPTs, fsync and atomically
   replace; original retained at PATH.before-expansion. Never shrinks/edits APFS. */
int hv_disk_expand(const char *path,uint64_t bytes,unsigned *last_apfs,char *error,size_t error_bytes);
/* Sizes describe the actual raw GPT, not a saved settings value. Preparation
   relocates only a validated trailing Recovery container on a private clone;
   APFS data-volume growth remains the responsibility of macOS diskutil. */
typedef struct HvDiskExpansionInfo {
 uint64_t disk_bytes, apfs_bytes, contiguous_bytes, recovery_bytes;
 unsigned apfs_partition, recovery_partition, can_prepare;
} HvDiskExpansionInfo;
int hv_disk_expansion_info(const char *path,HvDiskExpansionInfo *info,char *error,size_t error_bytes);
int hv_disk_prepare_apfs(const char *path,HvDiskExpansionInfo *info,char *error,size_t error_bytes);
#endif
