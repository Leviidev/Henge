/* Certification test: the HCI event-return path at the xHCI layer.
 *
 * Drives the SHIPPED devices/xhci.c (included directly, so its static
 * control handler and EP0 runner are the exact binary code) with real TRBs
 * in guest RAM, exactly as the guest did:
 *   1. SET_CONFIGURATION (00 09, value 1) on the BT slot's EP0.
 *   2. An HCI command over the control pipe in the guest's real form,
 *      bmRequestType 0x21 / bRequest 0x00, OUT data stage = HCI Reset
 *      (opcode 0x0C03, bytes 03 0C 00).
 *   3. A posted interrupt-IN transfer on interface 0's event endpoint
 *      (DCI 3), drained via hv_xhci_poll: the Command Complete for Reset
 *      (event 0x0E, opcode echo 0x0C03, status 0x00) MUST be delivered.
 *   4. The same for Read Local Version 0x1001 via 0x21, requiring its
 *      Command Complete with the BCM version payload.
 *   5. Regression: the spec form 0x20 / 0x00 keeps working identically.
 *   6. Negative semantics: a device-to-host class request (0xA1) and a
 *      class OUT request with bRequest != 0 must NOT reach the HCI core.
 *
 * On the code without the 0x21 dispatch fix, steps 2-4 fail (commands_seen
 * stays 0, no event is ever queued): that is the controlled reproduction.
 * Build (per tree): clang -std=c11 -Wall -Wextra -O2 -g -Icore -Ihost
 *   -Idevices tests/test_bt_hci21.c <ENGINE+DEV objects except xhci.o>
 *   <METAL_LIBS> -o test_bt_hci21
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xhci.c" /* the shipped transport, statics and all */

static HvMachine m;
static uint8_t ram_buf[1 << 20];
#define RAM_PA 0x10000000ull
#define DCBAA_PA (RAM_PA + 0x0000)
#define OUTCTX_PA (RAM_PA + 0x1000)
#define EP0_PA (RAM_PA + 0x2000)
#define EVT_PA (RAM_PA + 0x3000)
#define CMDBUF_PA (RAM_PA + 0x4000)
#define EVTBUF_PA (RAM_PA + 0x5000)
#define BT_SLOT 2

static int checks, failures;
static void check(const char *what, long got, long want) {
    checks++;
    if (got != want) {
        printf("  FAIL %s: %ld, expected %ld\n", what, got, want);
        failures++;
    } else {
        printf("  ok   %s\n", what);
    }
}

static void put_trb(uint64_t ring_pa, int idx, uint64_t param, uint32_t status, uint32_t control) {
    uint32_t trb[4] = {(uint32_t)param, (uint32_t)(param >> 32), status, control | 1u /* cycle */};
    hv_phys_write(&m, ring_pa + 16ull * (unsigned)idx, trb, 16);
}
static void clear_ring(uint64_t ring_pa) {
    uint8_t z[16 * 8] = {0};
    hv_phys_write(&m, ring_pa, z, sizeof z);
}

/* One EP0 control transfer on the BT slot: SETUP (+ optional data stage)
 * + STATUS, queued then drained in a single run_ep0_bt call, mirroring
 * the guest's queue-then-ring behaviour. trt: 0 none, 2 OUT, 3 IN. */
static void ep0_transfer(HvXhci *x, const uint8_t setup[8], uint64_t data_pa, uint32_t data_len, int trt) {
    clear_ring(EP0_PA);
    x->bep[1].dequeue = EP0_PA;
    x->bep[1].ccs = 1;
    x->bep_running[1] = 1;
    uint64_t sp = (uint64_t)setup[0] | (uint64_t)setup[1] << 8 | (uint64_t)setup[2] << 16 |
                  (uint64_t)setup[3] << 24 | (uint64_t)setup[4] << 32 | (uint64_t)setup[5] << 40 |
                  (uint64_t)setup[6] << 48 | (uint64_t)setup[7] << 56;
    int i = 0;
    put_trb(EP0_PA, i++, sp, setup[6] | (uint32_t)setup[7] << 8,
            (uint32_t)TRB_SETUP << 10 | (uint32_t)trt << 16);
    if (trt) {
        int dir_in = trt == 3;
        put_trb(EP0_PA, i++, data_pa, data_len, (uint32_t)TRB_DATA << 10 | (uint32_t)dir_in << 16);
    }
    put_trb(EP0_PA, i++, 0, 0, (uint32_t)TRB_STATUS << 10 | (uint32_t)(trt == 2) << 16);
    run_ep0_bt(x, BT_SLOT);
}

/* Post one interrupt-IN transfer on DCI 3 and poll; returns bytes copied
 * into the guest event buffer (0 when nothing was delivered). */
static uint32_t poll_event(HvXhci *x, uint8_t *out, uint32_t cap) {
    uint8_t z[64] = {0};
    hv_phys_write(&m, EVTBUF_PA, z, sizeof z);
    clear_ring(EVT_PA);
    x->bep[BT_DCI_EVT].dequeue = EVT_PA;
    x->bep[BT_DCI_EVT].ccs = 1;
    x->bep_running[BT_DCI_EVT] = 1;
    put_trb(EVT_PA, 0, EVTBUF_PA, 64, (uint32_t)TRB_NORMAL << 10);
    hv_xhci_poll(x);
    /* The runner writes exactly the event packet; find its length from
     * the event's own plen byte (event packet = 2 + plen). */
    hv_phys_read(&m, EVTBUF_PA, out, cap);
    if (out[0] == 0) return 0;
    return (uint32_t)(2 + out[1]) <= cap ? (uint32_t)(2 + out[1]) : 0;
}

int main(void) {
    setenv("HV_BT_PERSONALITY", "bcm20702", 1);
    if (hv_machine_init(&m, 4 << 20) != 0) return 2;
    hv_machine_add_ram(&m, RAM_PA, sizeof ram_buf, ram_buf, 0);
    uint64_t dcbaa[HV_XHCI_SLOTS + 1] = {0};
    dcbaa[BT_SLOT] = OUTCTX_PA;
    hv_phys_write(&m, DCBAA_PA, dcbaa, sizeof dcbaa);

    HvXhci *x = calloc(1, sizeof *x);
    x->m = &m;
    pthread_mutex_init(&x->mu, NULL);
    hv_bt_init(&x->bt);
    x->bt_present = 1;
    x->bt_slot = BT_SLOT;
    x->dcbaap = DCBAA_PA;

    uint8_t ev[64];
    uint32_t n;

    printf("scenario: SET_CONFIGURATION 1 on the modeled dongle\n");
    static const uint8_t setcfg[8] = {0x00, 0x09, 0x01, 0x00, 0, 0, 0, 0};
    ep0_transfer(x, setcfg, 0, 0, 0);
    check("bt_configured is 1 after SET_CONFIGURATION", x->bt_configured, 1);

    printf("scenario: HCI Reset via bmRequestType 0x21 / bRequest 0x00\n");
    static const uint8_t reset_cmd[3] = {0x03, 0x0c, 0x00}; /* opcode 0x0C03, plen 0 */
    hv_phys_write(&m, CMDBUF_PA, reset_cmd, sizeof reset_cmd);
    static const uint8_t setup21[8] = {0x21, 0x00, 0, 0, 0, 0, 3, 0};
    ep0_transfer(x, setup21, CMDBUF_PA, 3, 2);
    check("core saw the 0x21 Reset command", (long)x->bt.commands_seen, 1);
    check("Command Complete queued in the core", hv_bt_event_pending(&x->bt), 1);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("reset event delivered on interrupt-IN (len 6)", (long)n, 6);
    check("reset event code 0x0E (Command Complete)", ev[0], 0x0e);
    check("reset opcode echo 0x0C03", ev[3] | ev[4] << 8, 0x0c03);
    check("reset status 0x00", ev[5], 0);

    printf("scenario: Read Local Version via 0x21 / 0x00\n");
    static const uint8_t ver_cmd[3] = {0x01, 0x10, 0x00}; /* opcode 0x1001, plen 0 */
    hv_phys_write(&m, CMDBUF_PA, ver_cmd, sizeof ver_cmd);
    ep0_transfer(x, setup21, CMDBUF_PA, 3, 2);
    check("core saw the 0x21 Version command", (long)x->bt.commands_seen, 2);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("version event delivered on interrupt-IN (len 14)", (long)n, 14);
    check("version event code 0x0E", ev[0], 0x0e);
    check("version opcode echo 0x1001", ev[3] | ev[4] << 8, 0x1001);
    check("version status 0x00", ev[5], 0);
    check("version HCI version 6 (BT 4.0, BCM payload)", ev[6], 6);
    check("version manufacturer Broadcom 0x000F", ev[10] | ev[11] << 8, 0x000f);

    printf("scenario: regression, spec form 0x20 / 0x00 still reaches the core\n");
    hv_phys_write(&m, CMDBUF_PA, reset_cmd, sizeof reset_cmd);
    static const uint8_t setup20[8] = {0x20, 0x00, 0, 0, 0, 0, 3, 0};
    ep0_transfer(x, setup20, CMDBUF_PA, 3, 2);
    check("core saw the 0x20 Reset command", (long)x->bt.commands_seen, 3);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("0x20 reset event delivered (len 6)", (long)n, 6);
    check("0x20 reset opcode echo 0x0C03", ev[3] | ev[4] << 8, 0x0c03);

    printf("scenario: negative semantics stay out of the core\n");
    static const uint8_t setup_a1[8] = {0xa1, 0x00, 0, 0, 0, 0, 3, 0}; /* class IN */
    ep0_transfer(x, setup_a1, CMDBUF_PA, 3, 3);
    check("0xA1 class IN did not reach the core", (long)x->bt.commands_seen, 3);
    static const uint8_t setup_21_req[8] = {0x21, 0x0a, 0, 0, 0, 0, 3, 0}; /* bRequest != 0 */
    hv_phys_write(&m, CMDBUF_PA, reset_cmd, sizeof reset_cmd);
    ep0_transfer(x, setup_21_req, CMDBUF_PA, 3, 2);
    check("0x21 bRequest 0x0A did not reach the core", (long)x->bt.commands_seen, 3);
    check("no event queued by the negative probes", hv_bt_event_pending(&x->bt), 0);

    printf("test_bt_hci21: %d checks, %d failures\n", checks, failures);
    printf("%s\n", failures == 0 ? "HCI21 SCENARIO PASS" : "HCI21 SCENARIO FAIL");
    return failures != 0;
}
