#include "pvg_lite.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Real mapper MMIO with a controllable GPU completion boundary: no sleeps or
   dependence on how quickly the host GPU happens to finish a command. */
#define RAM_PA 0x80000000ull
#define IOSFC_PA 0x30210000ull
#define RING_SIZE 8
static HvMachine machine;
static HvCpu cpu;
static HvPvgLite *lite;
static uint8_t *ram;
static int checks, failures, unmaps, destroyed, pending;
static struct { HvPvgLite *lite; uint64_t index; } completions[32];
static int renderer;

static void check(const char *what, int ok) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static void finish(unsigned n) {
    HvPvgLite *p = completions[n].lite;
    if (!p) abort();
    completions[n].lite = NULL;
    hv_pvg_lite_mapper_done(p, completions[n].index);
}

HvPvgMetal *hv_pvg_metal_create(HvPvgLite *p) { return (HvPvgMetal *)&renderer; }
void hv_pvg_metal_after_gpu(HvPvgMetal *m, HvPvgLite *p, uint64_t index) {
    if (pending == 32) abort();
    completions[pending].lite = p;
    completions[pending++].index = index;
}
void hv_pvg_metal_unmap(HvPvgMetal *m, uint32_t mapping) { unmaps++; }
void hv_pvg_metal_quiesce(HvPvgMetal *m) {
    for (int i = 0; i < pending; i++) if (completions[i].lite) finish((unsigned)i);
}
void hv_pvg_metal_destroy(HvPvgMetal *m) { if (m) hv_pvg_metal_quiesce(m), destroyed++; }
void hv_pvg_metal_set_layer(HvPvgMetal *m, void *layer) {}
void hv_pvg_metal_cursor_moved(HvPvgMetal *m) {}
uint64_t hv_pvg_metal_gpu_frames(HvPvgMetal *m) { return 0; }
int hv_pvg_metal_snapshot(HvPvgMetal *m, uint8_t *p, uint32_t w, uint32_t h) { return -1; }
int hv_pvg_metal_frame(HvPvgMetal *m, const uint8_t **p, uint32_t *w, uint32_t *h) { return -1; }
size_t hv_pvg_metal_display_state(HvPvgMetal *m, void *out, size_t cap) { return 0; }
void hv_pvg_metal_set_display_state(HvPvgMetal *m, const void *in, size_t len) {}
void hv_pvg_metal_submit(HvPvgMetal *m, HvPvgLite *p, uint32_t ch, uint32_t *cmd, uint32_t len) { free(cmd); }

static void wr(uint64_t off, uint64_t value) { hv_phys_write(&machine, IOSFC_PA + off, &value, 8); }
static uint64_t done(void) {
    uint64_t value = UINT64_MAX;
    hv_phys_read(&machine, IOSFC_PA + 0x1020, &value, 8);
    return value;
}
static void submit(uint64_t index, uint32_t op) {
    uint32_t entry[4] = {op, (uint32_t)index, 0, 0};
    memcpy(ram + ((index - 1) % RING_SIZE) * 16, entry, sizeof entry);
    wr(0x1018, index);
}

int main(void) {
    unsetenv("HV_PVG_NO_METAL");
    if (hv_machine_init(&machine, 4 << 20)) return 1;
    ram = aligned_alloc(0x4000, 0x4000);
    if (!ram || hv_machine_add_ram(&machine, RAM_PA, 0x4000, ram, 0)) return 1;
    memset(ram, 0, 0x4000);
    hv_cpu_reset(&cpu, &machine);
    HvGic *gic = hv_gicv3_create(&machine, 0x10000000, 0x10400000);
    lite = hv_pvg_lite_create(&machine, gic, 0x30200000, IOSFC_PA, 40, 41);
    wr(0x1000, RAM_PA);
    wr(0x1008, RING_SIZE);
    submit(1, 2);
    check("without a renderer unmap completes immediately", done() == 1 && !pending);
    uint8_t state = 0;
    hv_pvg_lite_set_display_state(lite, &state, sizeof state); /* lazily create the mock renderer */
    submit(2, 1);
    check("map without earlier GPU unmap completes immediately", done() == 2 && !pending);
    submit(3, 2);
    check("unmap waits for GPU", done() == 2 && pending == 1 && unmaps == 1);
    wr(0x1018, 3);
    check("repeated doorbell does not replay unmap or fence", done() == 2 && pending == 1 && unmaps == 1);
    submit(4, 1);
    check("following map cannot overtake pending unmap", done() == 2 && pending == 2);
    finish(0);
    check("first GPU completion only releases its batch", done() == 3);
    finish(1);
    check("following batch becomes visible after completion", done() == 4);
    submit(5, 3);
    check("no remaining GPU work: immediate completion resumes", done() == 5 && pending == 2);
    submit(6, 2);
    submit(7, 1);
    finish(3);
    finish(2);
    check("callbacks arriving out of order do not rewind the ring", done() == 7 && unmaps == 2);
    submit(8, 2);
    submit(9, 2); /* physical ring wraps while completions are held */
    check("wrapped slots are each unmapped once", done() == 7 && unmaps == 4);
    hv_pvg_lite_quiesce(lite);
    check("snapshot quiesce drains mapper callbacks", done() == 9);
    size_t bytes = hv_pvg_lite_state(lite, NULL, 0);
    void *saved = malloc(bytes);
    hv_pvg_lite_state(lite, saved, bytes);
    submit(10, 2);
    hv_pvg_lite_quiesce(lite);
    check("restore accepts existing snapshot format", hv_pvg_lite_set_state(lite, saved, bytes) == 0);
    check("restore brings back completed index", done() == 9);
    submit(10, 2);
    check("restored mapper does not skip an unmap", unmaps == 6 && done() == 9);
    free(saved);
    hv_pvg_lite_destroy(lite);
    check("destroy drains outstanding callbacks before freeing mapper", destroyed == 1 && !completions[pending - 1].lite);
    pthread_mutex_destroy(&gic->mu);
    free(gic);
    hv_machine_free(&machine);
    free(ram);
    printf("PVG mapper: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
