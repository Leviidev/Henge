/* Exercise the guest-facing USB path, without a ROM or a guest installation. */
#include "machine.h"
#include "xhci.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BASE 0x100000ull
#define RING (BASE + 0x3000)
#define DATA (BASE + 0x5000)
static HvMachine machine;
static HvPcie bus;
static uint8_t memory[65536];

static void write_trb(uint64_t at, uint64_t pointer, uint32_t length, uint32_t flags) {
    uint32_t trb[] = {(uint32_t)pointer, (uint32_t)(pointer >> 32), length, flags | 1};
    assert(hv_phys_write(&machine, at, trb, sizeof trb) == 0);
}
static void prepare_slot(HvXhci *x, int dev) {
    x->slots[3].dev = dev;
    x->dcbaap = BASE + 0x1000;
    uint64_t context = BASE + 0x2000;
    assert(hv_phys_write(&machine, x->dcbaap + 3 * 8, &context, 8) == 0);
    memset(memory + 0x3000, 0, 0x1000);
    memset(memory + 0x5000, 0xcc, 512);
}
static void control(HvXhci *x, uint8_t type, uint8_t request, uint16_t value, uint16_t length) {
    prepare_slot(x, 2);
    x->slots[3].ep[1] = (HvXhciRing){RING, 1};
    uint8_t setup[] = {type, request, value & 255, value >> 8, 0, 0, length & 255, length >> 8};
    uint64_t packed;
    memcpy(&packed, setup, 8);
    write_trb(RING, packed, 8, 2u << 10 | 1u << 6);
    write_trb(RING + 16, DATA, length, 3u << 10 | 1u << 16);
    write_trb(RING + 32, 0, 0, 4u << 10);
    x->pci.bar_write(&x->pci, 0, 0x2000 + 3 * 4, 1, 4);
}
static void receive(HvXhci *x, const uint8_t expected[HV_TS_REPORT_LEN]) {
    prepare_slot(x, 2);
    memset(x->slots[3].ep_running, 0, sizeof x->slots[3].ep_running);
    x->slots[3].ep[3] = (HvXhciRing){RING, 1};
    write_trb(RING, DATA, HV_TS_REPORT_LEN, 1u << 10);
    x->pci.bar_write(&x->pci, 0, 0x2000 + 3 * 4, 3, 4);
    assert(memcmp(memory + 0x5000, expected, HV_TS_REPORT_LEN) == 0);
}
static void finish_release(HvXhci *x, const uint8_t lifted[HV_TS_REPORT_LEN], const uint8_t up[HV_TS_REPORT_LEN]) {
    assert(hv_xhci_touchscreen_connected(x) && x->ts_release_phase == 1);
    assert(!hv_xhci_touchscreen_report(x, lifted));
    receive(x, lifted);
    x->ts_release_at_ns = 1; hv_xhci_poll(x);
    receive(x, up);
    x->ts_release_at_ns = 1; hv_xhci_poll(x);
    assert(!hv_xhci_touchscreen_connected(x));
    assert(x->ts_rhead == x->ts_rtail && !x->ts_state[31]);
}
int main(void) {
    assert(hv_machine_init(&machine, 1 << 20) == 0);
    assert(hv_machine_add_ram(&machine, BASE, sizeof memory, memory, 0) == 0);
    bus.m = &machine;
    setenv("HV_USB_TOUCHSCREEN", "0", 1);
    HvXhci *off = hv_xhci_create(&machine, &bus);
    assert(off && !off->ts_enabled);
    assert((off->pci.bar_read(&off->pci, 0, 4, 4) >> 24) == 2);
    assert(((off->pci.bar_read(&off->pci, 0, 0x808, 4) >> 8) & 255) == 2);
    uint8_t up[HV_TS_REPORT_LEN] = {1};
    assert(!hv_xhci_touchscreen_report(off, up));
    assert(!hv_xhci_touchscreen_connect(off, 1));
    setenv("HV_USB_TOUCHSCREEN", "1", 1);
    HvXhci *x = hv_xhci_create(&machine, &bus);
    assert(x && x->ts_enabled);
    assert((x->pci.bar_read(&x->pci, 0, 4, 4) >> 24) == 3);
    assert(((x->pci.bar_read(&x->pci, 0, 0x808, 4) >> 8) & 255) == 3);
    assert(x->pci.bar_read(&x->pci, 0, 0x460, 4) & 1);

    control(x, 0x80, 6, 0x0100, 18);
    assert(memory[0x5000] == 18 && memory[0x5001] == 1);
    assert(memory[0x5008] == 9 && memory[0x5009] == 0x12);
    control(x, 0x80, 6, 0x0200, 34);
    uint16_t descriptor_size = memory[0x5000 + 25] | memory[0x5000 + 26] << 8;
    assert(descriptor_size > 256 && descriptor_size < 512);
    assert(memory[0x5000 + 15] == 0 && memory[0x5000 + 16] == 0);
    control(x, 0x81, 6, 0x2200, descriptor_size);
    assert(memory[0x5000] == 5 && memory[0x5001] == 13 && memory[0x5003] == 4);
    assert(memory[0x5000 + descriptor_size - 1] == 0xc0);
    control(x, 0xa1, 1, 0x0302, 2);
    assert(memory[0x5000] == 2 && memory[0x5001] == HV_TS_FINGERS);
    control(x, 0xa1, 1, 0x0101, HV_TS_REPORT_LEN);
    assert(memcmp(memory + 0x5000, up, sizeof up) == 0);

    uint8_t down[HV_TS_REPORT_LEN] = {1, 3, 42, 0xff, 0x7f, 0, 0};
    down[31] = 1;
    uint8_t lifted[HV_TS_REPORT_LEN]; memcpy(lifted, down, sizeof down); lifted[1] = 2;
    assert(hv_xhci_touchscreen_report(x, down));
    assert(hv_xhci_touchscreen_report(x, lifted));
    assert(hv_xhci_touchscreen_report(x, up));
    receive(x, down); receive(x, lifted); receive(x, up);
    assert(x->ts_delivered == 3);
    uint8_t five[HV_TS_REPORT_LEN] = {1}; five[31] = HV_TS_FINGERS;
    for (int i = 0; i < HV_TS_FINGERS; i++) {
        five[1 + 6*i] = 3; five[2 + 6*i] = (uint8_t)(i+1);
        five[3 + 6*i] = (uint8_t)(10*i); five[5 + 6*i] = (uint8_t)(20*i);
    }
    assert(hv_xhci_touchscreen_report(x, five)); receive(x, five);
    control(x, 0xa1, 1, 0x0101, HV_TS_REPORT_LEN);
    assert(memcmp(memory + 0x5000, five, sizeof five) == 0);
    assert(hv_xhci_touchscreen_report(x, up)); receive(x, up);
    uint8_t invalid[HV_TS_REPORT_LEN]; memcpy(invalid, down, sizeof down); invalid[4] = 0x80;
    assert(!hv_xhci_touchscreen_report(x, invalid));
    memcpy(invalid, down, sizeof down); invalid[31] = 6;
    assert(!hv_xhci_touchscreen_report(x, invalid));
    memcpy(invalid, down, sizeof down); invalid[31] = 2; memcpy(invalid + 7, invalid + 1, 6);
    assert(!hv_xhci_touchscreen_report(x, invalid));
    for (int i = 0; i < HV_TS_REPORTS; i++) assert(hv_xhci_touchscreen_report(x, down));
    assert(!hv_xhci_touchscreen_report(x, down));
    hv_xhci_poll(x);
    assert(!hv_xhci_touchscreen_connected(x));
    assert(x->ts_rhead == x->ts_rtail);
    assert(hv_xhci_touchscreen_connect(x, 1)); hv_xhci_poll(x);
    assert(hv_xhci_touchscreen_report(x, down)); receive(x, down);
    for (int i = 0; i < HV_TS_REPORTS; i++) assert(hv_xhci_touchscreen_report(x, down));
    assert(!hv_xhci_touchscreen_report(x, down)); hv_xhci_poll(x);
    finish_release(x, lifted, up);
    x->pci.bar_write(&x->pci, 0, 0x40, 2, 4);
    assert(x->ts_rhead == x->ts_rtail && x->ts_state[31] == 0);
    assert(!hv_xhci_touchscreen_connect(x, 2));
    assert(hv_xhci_touchscreen_connect(x, 1)); hv_xhci_poll(x);
    assert(hv_xhci_touchscreen_report(x, down));
    assert(hv_xhci_touchscreen_connect(x, 0));
    hv_xhci_poll(x);
    assert(!(x->pci.bar_read(&x->pci, 0, 0x460, 4) & 1));
    assert(x->ts_state[31] == 0 && x->ts_rhead == x->ts_rtail);
    assert(!hv_xhci_touchscreen_report(x, down));
    x->pci.bar_write(&x->pci, 0, 0x40, 2, 4);
    assert(!(x->pci.bar_read(&x->pci, 0, 0x460, 4) & 1));
    assert(hv_xhci_touchscreen_connect(x, 1));
    hv_xhci_poll(x);
    assert(x->pci.bar_read(&x->pci, 0, 0x460, 4) & 1);
    assert(hv_xhci_touchscreen_report(x, up)); receive(x, up);
    /* An identical request must not manufacture a second port change. */
    x->pci.bar_write(&x->pci, 0, 0x460, (1u << 9) | (1u << 17), 4);
    assert(hv_xhci_touchscreen_connect(x, 1)); hv_xhci_poll(x);
    assert(!(x->pci.bar_read(&x->pci, 0, 0x460, 4) & (1u << 17)));
    setenv("HV_USB_TOUCHSCREEN_DELAYED", "1", 1);
    HvXhci *delayed = hv_xhci_create(&machine, &bus);
    unsetenv("HV_USB_TOUCHSCREEN_DELAYED");
    assert(delayed && delayed->ts_enabled && !delayed->ts_connected);
    assert((delayed->pci.bar_read(&delayed->pci, 0, 4, 4) >> 24) == 3);
    assert(!hv_xhci_touchscreen_report(delayed, up));
    assert(hv_xhci_touchscreen_connect(delayed, 1)); hv_xhci_poll(delayed);
    assert(delayed->pci.bar_read(&delayed->pci, 0, 0x460, 4) & 1);
    control(delayed, 0xa1, 1, 0x0303, 3);
    assert(delayed->slots[3].ep[1].dequeue == RING && memory[0x5000] == 0xcc);
    assert(delayed->ts_ep0_waiting && !delayed->ts_mapped);
    assert(hv_xhci_touchscreen_mapped(delayed)); hv_xhci_poll(delayed);
    assert(!delayed->ts_ep0_waiting && memory[0x5000] == 3 && memory[0x5001] == 60 && memory[0x5002] == 0);
    /* A lost helper must cancel a held contact even if the UI stops polling. */
    assert(hv_xhci_touchscreen_report(delayed, down));
    receive(delayed, down);
    delayed->ts_deadline_ns = 1;
    hv_xhci_poll(delayed);
    finish_release(delayed, lifted, up);
    assert(hv_xhci_touchscreen_connect(delayed, 1)); hv_xhci_poll(delayed);
    assert(hv_xhci_touchscreen_report(delayed, down)); receive(delayed, down);
    assert(hv_xhci_touchscreen_connect(delayed, 0)); hv_xhci_poll(delayed);
    /* A guest that stops servicing its IN ring cannot hold teardown forever. */
    delayed->ts_release_limit_ns = 1; hv_xhci_poll(delayed);
    assert(!hv_xhci_touchscreen_connected(delayed));
    unsetenv("HV_USB_TOUCHSCREEN");
    HvXhci *normal = hv_xhci_create(&machine, &bus);
    assert(normal && normal->ts_enabled && !normal->ts_connected);
    assert((normal->pci.bar_read(&normal->pci, 0, 4, 4) >> 24) == 3);
    puts("USB touchscreen: descriptors, transfers, lifts, validation, overflow, reset, hot-plug and watchdog passed");
    return 0;
}
