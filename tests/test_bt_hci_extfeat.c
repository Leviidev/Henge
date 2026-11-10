/* Certification test: Read Local Extended Features (0x1004) and
 * the 0x1002 Supported Commands mask gate that decides whether the guest's
 * OI layer will ISSUE the command at all.
 *
 * Background: in the failing boot the guest consumed the core's
 * 0x1002 mask, then failed Read Local Extended Features LOCALLY with OI
 * status 628 before anything reached the wire. The OI dispatcher refuses a
 * command whose bit is clear in the cached Supported Commands mask
 * (descriptor halfword = (octet << 8) | bitmask; 0x1004 = octet 14, 0x40).
 * The earlier mask had octet 14 = 0x38, so the send never happened, and the
 * earlier core had no 0x1004 case anyway (default empty success).
 *
 * This test drives the exact guest form (bmRequestType 0x21 / bRequest 0x00
 * control transfers through the shipped devices/xhci.c) with the six-command
 * init sequence the guest ran in that boot, then 0x1004 with plen 1 (bytes
 * 04 10 01 <page>) for pages 0, 1, 2 and an out-of-range page, and the
 * next chain command 0x1005 whose mask bit (octet 14, 0x80) was also clear.
 * It also replays the guest's own gate arithmetic against the SERVED mask:
 * every init-chain opcode whose completion callback passes a raw failure
 * status to the init checker must have its descriptor bit set.
 *
 * On the earlier tree the mask checks, the 0x1004 payload checks and the
 * out-of-range check fail (controlled reproduction); on this tree all
 * checks pass.
 * Build (per tree): see the xhci-suite build pattern.
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

/* Post one interrupt-IN transfer on DCI 3 (128-byte buffer: the 0x1002
 * Command Complete is 70 bytes) and poll; returns the event length. */
static uint32_t poll_event(HvXhci *x, uint8_t *out, uint32_t cap) {
    uint8_t z[128] = {0};
    hv_phys_write(&m, EVTBUF_PA, z, sizeof z);
    clear_ring(EVT_PA);
    x->bep[BT_DCI_EVT].dequeue = EVT_PA;
    x->bep[BT_DCI_EVT].ccs = 1;
    x->bep_running[BT_DCI_EVT] = 1;
    put_trb(EVT_PA, 0, EVTBUF_PA, 128, (uint32_t)TRB_NORMAL << 10);
    hv_xhci_poll(x);
    hv_phys_read(&m, EVTBUF_PA, out, cap);
    if (out[0] == 0) return 0;
    return (uint32_t)(2 + out[1]) <= cap ? (uint32_t)(2 + out[1]) : 0;
}

/* Send one HCI command packet in the guest's real form: 0x21 / 0x00 with
 * an OUT data stage of exactly the packet (3 + plen bytes). */
static void send21(HvXhci *x, const uint8_t *cmd, uint32_t len) {
    hv_phys_write(&m, CMDBUF_PA, cmd, len);
    uint8_t setup[8] = {0x21, 0x00, 0, 0, 0, 0, (uint8_t)len, (uint8_t)(len >> 8)};
    ep0_transfer(x, setup, CMDBUF_PA, len, 2);
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

    uint8_t ev[128];
    uint32_t n;
    long seen = 0;

    printf("scenario: SET_CONFIGURATION 1 on the modeled dongle\n");
    static const uint8_t setcfg[8] = {0x00, 0x09, 0x01, 0x00, 0, 0, 0, 0};
    ep0_transfer(x, setcfg, 0, 0, 0);
    check("bt_configured is 1 after SET_CONFIGURATION", x->bt_configured, 1);

    printf("scenario: guest init sequence, Reset / Version / Supported Commands\n");
    static const uint8_t reset_cmd[3] = {0x03, 0x0c, 0x00};
    send21(x, reset_cmd, 3);
    check("core saw Reset", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("reset CC len 6", (long)n, 6);
    check("reset CC status 0", ev[5], 0);

    static const uint8_t ver_cmd[3] = {0x01, 0x10, 0x00};
    send21(x, ver_cmd, 3);
    check("core saw Read Local Version", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("version CC len 14", (long)n, 14);
    check("version CC status 0", ev[5], 0);

    static const uint8_t mask_cmd[3] = {0x02, 0x10, 0x00};
    send21(x, mask_cmd, 3);
    check("core saw Read Local Supported Commands", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("mask CC len 70 (64-byte mask)", (long)n, 70);
    check("mask CC opcode echo 0x1002", ev[3] | ev[4] << 8, 0x1002);
    check("mask CC status 0", ev[5], 0);
    const uint8_t *mask = ev + 6; /* Supported_Commands payload */
    check("mask octet 0 = 0x23 (Inquiry, Inquiry Cancel (claim), Disconnect)", mask[0], 0x23);
    check("mask octet 5 = 0xC0 (Set Event Mask, Reset)", mask[5], 0xc0);
    check("mask octet 22 = 0x04 (Set Event Mask Page 2)", mask[22], 0x04);
    check("mask octet 25 = 0xB7 (LE mask/version/buffer/features)", mask[25], 0xb7);
    check("mask octet 26 = 0x7F (LE read/write set; +0x200F)", mask[26], 0x7f);
    check("mask octet 28 = 0x08 (LE Read Supported States)", mask[28], 0x08);

    printf("scenario: the guest's OI gate arithmetic against the served mask\n");
    /* Descriptor mapping derived from bluetoothd's command table:
     * halfword = (octet << 8) | bitmask. A clear bit makes the OI
     * dispatcher return 628 locally; the init callbacks for these opcodes
     * pass a raw nonzero status to the init checker, which aborts init. */
    check("gate: 0x1001 bit (octet 14, 0x08) set", (mask[14] & 0x08) != 0, 1);
    check("gate: 0x1002 bit (octet 14, 0x10) set", (mask[14] & 0x10) != 0, 1);
    check("gate: 0x1003 bit (octet 14, 0x20) set", (mask[14] & 0x20) != 0, 1);
    check("gate: 0x1004 bit (octet 14, 0x40) set (fix)", (mask[14] & 0x40) != 0, 1);
    check("gate: 0x1005 bit (octet 14, 0x80) set (fix)", (mask[14] & 0x80) != 0, 1);
    check("gate: 0x1009 bit (octet 15, 0x02) set", (mask[15] & 0x02) != 0, 1);
    check("gate: 0x0C33 bit (octet 10, 0x40) set (fix)", (mask[10] & 0x40) != 0, 1);
    check("gate: 0x0C56 bit (octet 17, 0x40) set (fix)", (mask[17] & 0x40) != 0, 1);
    check("honesty: 0x0409 bit (octet 0, 0x10) still clear (core refuses it)",
          (mask[0] & 0x10) != 0, 0);

    printf("scenario: BD_ADDR and Local Supported Features complete the five\n");
    static const uint8_t addr_cmd[3] = {0x09, 0x10, 0x00};
    send21(x, addr_cmd, 3);
    check("core saw Read BD_ADDR", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("bd_addr CC len 12", (long)n, 12);
    check("bd_addr CC status 0", ev[5], 0);

    static const uint8_t feat_cmd[3] = {0x03, 0x10, 0x00};
    send21(x, feat_cmd, 3);
    check("core saw Read Local Supported Features", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("features CC len 14", (long)n, 14);
    check("features byte 7 = 0x87 (Extended Features bit set)", ev[6 + 7], 0x87);

    printf("scenario: 0x1004 page 2, the exact command the guest's init issues\n");
    static const uint8_t ext2_cmd[4] = {0x04, 0x10, 0x01, 0x02};
    send21(x, ext2_cmd, 4);
    check("core saw Read Local Extended Features (plen 1)", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("extfeat CC len 16 (6 + 10 payload)", (long)n, 16);
    check("extfeat event code 0x0E", ev[0], 0x0e);
    check("extfeat plen byte 14 (4 + 10)", ev[1], 14);
    check("extfeat opcode echo 0x1004", ev[3] | ev[4] << 8, 0x1004);
    check("extfeat status 0", ev[5], 0);
    check("extfeat Page_Number echoes the request (2)", ev[6], 2);
    check("extfeat Maximum_Page_Number 2", ev[7], 2);
    long p2_nonzero = 0;
    for (int i = 0; i < 8; i++) p2_nonzero |= ev[8 + i];
    check("extfeat page 2 features carry no bits", p2_nonzero, 0);

    printf("scenario: 0x1004 pages 0 and 1\n");
    static const uint8_t ext0_cmd[4] = {0x04, 0x10, 0x01, 0x00};
    send21(x, ext0_cmd, 4);
    check("core saw 0x1004 page 0", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("page 0 CC len 16", (long)n, 16);
    check("page 0 echo", ev[6], 0);
    long p0_nonzero = 0;
    for (int i = 0; i < 8; i++) p0_nonzero |= ev[8 + i];
    check("page 0 features carry no bits beyond the 0x1003 page", p0_nonzero, 0);

    static const uint8_t ext1_cmd[4] = {0x04, 0x10, 0x01, 0x01};
    send21(x, ext1_cmd, 4);
    check("core saw 0x1004 page 1", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("page 1 CC len 16", (long)n, 16);
    check("page 1 echo", ev[6], 1);
    check("page 1 byte 0 = 0x03 (LE Host + Simultaneous Host)", ev[8], 0x03);
    long p1_rest = 0;
    for (int i = 1; i < 8; i++) p1_rest |= ev[8 + i];
    check("page 1 remaining feature bytes zero", p1_rest, 0);

    printf("scenario: 0x1004 above the maximum page returns the spec error\n");
    static const uint8_t ext3_cmd[4] = {0x04, 0x10, 0x01, 0x03};
    send21(x, ext3_cmd, 4);
    check("core saw 0x1004 page 3", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("page 3 CC len 6 (status only)", (long)n, 6);
    check("page 3 status 0x11 (Unsupported Feature or Parameter Value)", ev[5], 0x11);

    printf("scenario: 0x1005 Read Buffer Size, the next raw-status chain step\n");
    static const uint8_t bufsize_cmd[3] = {0x05, 0x10, 0x00};
    send21(x, bufsize_cmd, 3);
    check("core saw Read Buffer Size", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    n = poll_event(x, ev, sizeof ev);
    check("buffer size CC len 13 (6 + 7)", (long)n, 13);
    check("buffer size CC status 0", ev[5], 0);
    check("buffer size ACL length 1021", ev[6] | ev[7] << 8, 1021);
    check("buffer size SCO length 64", ev[8], 64);
    check("buffer size ACL packets 4", ev[9] | ev[10] << 8, 4);
    check("buffer size SCO packets 4", ev[11] | ev[12] << 8, 4);

    printf("test_bt_hci_extfeat: %d checks, %d failures\n", checks, failures);
    printf("%s\n", failures == 0 ? "EXTFEAT SCENARIO PASS" : "EXTFEAT SCENARIO FAIL");
    return failures != 0;
}
