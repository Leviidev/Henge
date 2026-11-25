/* hvsparse grow IMAGE GIB: a bigger disk. hvsparse backup SRC DST: compressed. hvsparse pack SRC DST | hvsparse unpack SRC DST: see host/hvsparse.h. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hvsparse.h"

int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "pack")) return hv_sparse_pack(argv[2], argv[3]) ? 1 : 0;
    if (argc == 4 && !strcmp(argv[1], "unpack")) return hv_sparse_unpack(argv[2], argv[3], NULL, NULL) ? 1 : 0;
    if (argc == 4 && !strcmp(argv[1], "backup")) return hv_sparse_pack_compressed(argv[2], argv[3], NULL, NULL) ? 1 : 0;
    if (argc == 3 && !strcmp(argv[1], "verify")) return hv_sparse_verify(argv[2], NULL, NULL) ? 1 : 0;
#ifdef __APPLE__
    if (argc == 4 && !strcmp(argv[1], "grow")) {
        char err[256] = "";
        if (hv_disk_grow(argv[2], strtoull(argv[3], NULL, 0) << 30, err, sizeof err) == 0) return 0;
        fprintf(stderr, "%s\n", err);
        return 1;
    }
#endif
    fprintf(stderr, "usage: hvsparse pack|backup|unpack SRC DST, verify SRC, grow IMAGE GIB\n");
    return 2;
}
