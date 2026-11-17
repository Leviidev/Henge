#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include "pvg_lite.h"
#include "vmapple.h"
#include <stdlib.h>
#include <unistd.h>

/* Exercise real Metal command completion while the guest board is destroyed.
   Empty execs avoid simulator limitations on guest buffer-backed textures. */
static HvMachine machine;
static HvCpu cpus[2];
static HvVmapple board;

static void wr32(uint64_t at, uint32_t value) { hv_phys_write(&machine, at, &value, 4); }
static void wr64(uint64_t at, uint64_t value) { hv_phys_write(&machine, at, &value, 8); }

/* Use the real guest rings so the board owns the renderer and must drain its
   asynchronous unmap acknowledgements before freeing the graphics device. */
static int mapper_work(int cycle) {
    const uint64_t root = VMAPPLE_MEM + 0x4000, control = VMAPPLE_MEM + 0x8000;
    const uint64_t table = VMAPPLE_MEM + 0xc000, commands = VMAPPLE_MEM + 0x10000;
    const uint64_t mappings = VMAPPLE_MEM + 0x14000;
    wr32(VMAPPLE_GFX + 0x101c, (uint32_t)(root >> 14));
    wr32(VMAPPLE_GFX + 0x1030, (uint32_t)(control >> 14));
    wr32(root + 0x410, (uint32_t)(table >> 14));
    wr32(table, (uint32_t)(commands >> 14));
    for (unsigned i = 0; i < 64; i++) {
        uint32_t cmd[6] = {0x43, 24, i + 1, 0, 0, 0};
        memcpy(hv_phys_ptr(&machine, commands + i * sizeof cmd, sizeof cmd), cmd, sizeof cmd);
    }
    wr32(root + 0x400, 64 * 24);
    wr32(VMAPPLE_GFX + 0x1020, 1);
    wr64(VMAPPLE_IOSFC + 0x1000, mappings);
    wr64(VMAPPLE_IOSFC + 0x1008, 64);
    for (unsigned i = 0; i < 32; i++) {
        wr32(mappings + i * 16, 2);
        wr32(mappings + i * 16 + 4, i + 1);
        wr64(VMAPPLE_IOSFC + 0x1018, i + 1);
    }
    if (!(cycle & 1)) {
        hv_pvg_lite_quiesce(board.pvg);
        uint64_t done = 0;
        uint32_t stamp = 0;
        hv_phys_read(&machine, VMAPPLE_IOSFC + 0x1020, &done, 8);
        hv_phys_read(&machine, control + 4, &stamp, 4);
        if (done != 32 || stamp != 64) {
            fprintf(stderr, "GPU quiesce left mapper %llu/32, stamp %u/64\n", (unsigned long long)done, stamp);
            return -1;
        }
    } /* other cycles destroy the board with completions still queued */
    return 0;
}

int main(void) {
    alarm(30);
    for (int cycle = 0; cycle < 6; cycle++) @autoreleasepool {
        HvCfgParams cfg = {.nr_cpus = 2};
        if (hv_machine_init(&machine, 4 << 20) ||
            hv_vmapple_create(&board, &machine, cpus, 64 << 20, NULL, NULL, &cfg, NULL)) return 1;
        hv_vmapple_reset_cpu(&board);
        HvPvgMetal *metal = hv_pvg_metal_create(board.pvg);
        if (!metal) { fprintf(stderr, "Metal replay unavailable; lifecycle test cannot run\n"); return 1; }
        CAMetalLayer *layer = [CAMetalLayer layer];
        hv_pvg_metal_set_layer(metal, (__bridge void *)layer);
        for (int i = 0; i < 64; i++) {
            uint32_t *cmd = calloc(6, sizeof *cmd);
            cmd[0] = 0x43; cmd[1] = 24; cmd[2] = i + 1;
            hv_pvg_metal_submit(metal, board.pvg, 0, cmd, 24);
        }
        hv_pvg_metal_cursor_moved(metal);
        hv_pvg_metal_set_layer(metal, NULL);
        hv_pvg_metal_destroy(metal);
        if (mapper_work(cycle)) return 1;
        hv_vmapple_destroy(&board);
        hv_machine_free(&machine);
    }
    puts("Metal lifecycle: 6 cycles, 768 execs and 192 mapper unmaps drained");
    return 0;
}
