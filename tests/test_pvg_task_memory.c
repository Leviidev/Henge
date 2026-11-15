/* Exercise the production task walker with actual guest physical mappings. */
#include "../devices/pvg_lite.c"
#include <assert.h>

static uint8_t ram[8 * 0x4000];
static HvMachine machine;
static HvPvgLite pvg;
int main(void) {
    assert(!hv_machine_init(&machine, 1 << 20));
    assert(!hv_machine_add_ram(&machine, 0x4000, sizeof ram, ram, 0));
    pvg.m = &machine; pvg.task_root[1] = 1;
    uint32_t *root = (void *)ram, *leaf = (void *)(ram + 0x4000);
    root[0] = 2; root[1] = 1;
    leaf[0] = 3; leaf[1] = 4; leaf[4095] = 4;
    memset(ram + 0x8000, 0xa3, 0x4000);
    memset(ram + 0xc000, 0xa4, 0x4000);
    uint8_t bytes[32];
    assert(!hv_pvg_lite_task_read(&pvg, 1, 0x3ff0, bytes, sizeof bytes));
    for (unsigned i = 0; i < sizeof bytes; i++) assert(bytes[i] == (i < 16 ? 0xa3 : 0xa4));
    assert(!hv_pvg_lite_task_read(&pvg, 1, 0x3ff0, NULL, sizeof bytes));
    assert(hv_pvg_lite_task_read(&pvg, 1, 0x7ff0, NULL, sizeof bytes) == -1);
    assert(hv_pvg_lite_task_read(&pvg, 1, UINT64_MAX - 2, bytes, sizeof bytes) == -1);
    for (unsigned depth = 1; depth <= 3; depth++) {
        root[1] = depth;
        uint64_t pages = 1ull << (12 * depth), end = pages << 14;
        /* Root bits must not silently wrap into a valid low mapping. */
        assert(!hv_pvg_lite_task_page(&pvg, 1, end));
        assert(hv_pvg_lite_task_read(&pvg, 1, end, bytes, 1) == -1);
        uint32_t out[] = {99,99};
        hv_pvg_lite_task_pages(&pvg, 1, pages, 2, out);
        assert(!out[0] && !out[1]);
    }
    root[1] = 1;
    uint32_t out[3] = {99,99,99};
    hv_pvg_lite_task_pages(&pvg, 1, 4095, 3, out);
    assert(out[0] == 4 && !out[1] && !out[2]);
    hv_pvg_lite_task_pages(&pvg, 1, UINT64_MAX, 3, out);
    assert(!out[0] && !out[1] && !out[2]);
    assert(hv_pvg_lite_task_read(&pvg, 1, 0, NULL, UINT32_MAX) == -1);
    hv_machine_free(&machine);
    puts("PASS GPU task memory: copied and validation-only reads, unmapped blobs, all address widths and batch tail bounds");
}
