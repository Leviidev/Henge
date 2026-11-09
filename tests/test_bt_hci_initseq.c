/* Certification test: FULL guest init-sequence alignment.
 *
 * Supersedes tests/test_bt_hci_extfeat.c : every extfeat check is
 * preserved here (one deliberate expectation updated: mask octet 26,
 * 0x3F to 0x7F, because this core implements 0x200F and claims its bit), and this
 * harness adds (a) a replay of the guest's OI gate arithmetic for EVERY
 * step of the init-sequence table against the
 * served 0x1002 mask, and (b) a drive of every claimed or newly
 * implemented command in the guest's real 21 00 form at its real plen, in
 * chain order, with the guest parsers' payload requirements asserted.
 *
 * Guest evidence summary (observed guest daemon behavior):
 * before issuing a command the OI dispatcher (0x100196848)
 * checks the command's descriptor bit in the cached Supported Commands
 * mask; a clear bit returns OI status 628 locally, nothing is sent. Each
 * step's WRAPPER either tolerates 628 explicitly (advances) or passes any
 * nonzero return to the init failure handler 0x10028540c, which is the
 * dongle-failed teardown proven live in guest boots (0x1004) and (0x0C6D).
 * Completion callbacks are a second, independent level: some convert a
 * failure status to 0 before the init checker, some pass it raw.
 *
 * On the extfeat-only tree this harness fails with exactly the init-sequence
 * defect signature: gate bits for 0x0C6D, 0x200F, 0x0C31, 0x0C5B, 0x2060 clear in
 * the served mask; 0x200F and 0x2060 answered with the default empty
 * success (CC length 6). On this tree all checks pass.
 * Post-init update: the post-init claims move 0x0C14 from
 * the clear list to the pass list and add pass entries for 0x0C13 and
 * 0x0C52, the CBCrash-class post-init pair certified in full by
 * tests/test_bt_hci_postinit.c. One
 * expectation changes deliberately (0x0C14) and the count grows by 2.
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

static void send21(HvXhci *x, const uint8_t *cmd, uint32_t len) {
    hv_phys_write(&m, CMDBUF_PA, cmd, len);
    uint8_t setup[8] = {0x21, 0x00, 0, 0, 0, 0, (uint8_t)len, (uint8_t)(len >> 8)};
    ep0_transfer(x, setup, CMDBUF_PA, len, 2);
}

static HvXhci *x;
static long seen = 0;
static uint8_t ev[128];

/* Drive one command at its real plen and require a status-0 Command
 * Complete of the expected total length; returns event length. */
static uint32_t drive(const char *name, const uint8_t *cmd, uint32_t len,
                      uint16_t opcode, long want_len) {
    char lbl[96];
    send21(x, cmd, len);
    snprintf(lbl, sizeof lbl, "core saw %s", name);
    check(lbl, (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    uint32_t n = poll_event(x, ev, sizeof ev);
    snprintf(lbl, sizeof lbl, "%s CC len", name);
    check(lbl, (long)n, want_len);
    snprintf(lbl, sizeof lbl, "%s CC opcode echo", name);
    check(lbl, ev[3] | ev[4] << 8, opcode);
    snprintf(lbl, sizeof lbl, "%s CC status 0", name);
    check(lbl, ev[5], 0);
    return n;
}

int main(void) {
    setenv("HV_BT_PERSONALITY", "bcm20702", 1);
    if (hv_machine_init(&m, 4 << 20) != 0) return 2;
    hv_machine_add_ram(&m, RAM_PA, sizeof ram_buf, ram_buf, 0);
    uint64_t dcbaa[HV_XHCI_SLOTS + 1] = {0};
    dcbaa[BT_SLOT] = OUTCTX_PA;
    hv_phys_write(&m, DCBAA_PA, dcbaa, sizeof dcbaa);

    x = calloc(1, sizeof *x);
    x->m = &m;
    pthread_mutex_init(&x->mu, NULL);
    hv_bt_init(&x->bt);
    x->bt_present = 1;
    x->bt_slot = BT_SLOT;
    x->dcbaap = DCBAA_PA;

    uint32_t n;

    printf("scenario: SET_CONFIGURATION 1 on the modeled dongle\n");
    static const uint8_t setcfg[8] = {0x00, 0x09, 0x01, 0x00, 0, 0, 0, 0};
    ep0_transfer(x, setcfg, 0, 0, 0);
    check("bt_configured is 1 after SET_CONFIGURATION", x->bt_configured, 1);

    /* ---- extfeat flow, preserved: Reset / Version / SuppCmds ---- */
    printf("scenario: guest init sequence, Reset / Version / Supported Commands\n");
    static const uint8_t reset_cmd[3] = {0x03, 0x0c, 0x00};
    drive("Reset", reset_cmd, 3, 0x0c03, 6);

    static const uint8_t ver_cmd[3] = {0x01, 0x10, 0x00};
    drive("Read Local Version", ver_cmd, 3, 0x1001, 14);

    static const uint8_t mask_cmd[3] = {0x02, 0x10, 0x00};
    drive("Read Local Supported Commands", mask_cmd, 3, 0x1002, 70);
    const uint8_t *mask = ev + 6; /* Supported_Commands payload */
    check("mask octet 0 = 0x23 (Inquiry, Inquiry Cancel (claim), Disconnect)", mask[0], 0x23);
    check("mask octet 5 = 0xC0 (Set Event Mask, Reset)", mask[5], 0xc0);
    check("mask octet 22 = 0x04 (Set Event Mask Page 2)", mask[22], 0x04);
    check("mask octet 25 = 0xB7 (LE mask/version/buffer/features)", mask[25], 0xb7);
    check("mask octet 26 = 0x7F (LE read/write set; +0x200F)", mask[26], 0x7f);
    check("mask octet 28 = 0x08 (LE Read Supported States)", mask[28], 0x08);

    printf("scenario: FULL gate replay, every step of the sequence table\n");
    /* Steps the guest must be able to issue (bit set). Descriptor
     * halfword = (octet << 8) | bitmask, table at 0x100ba6168. */
    static const struct { const char *name; int octet; int bit; } pass_gates[] = {
        {"0x0C03 Reset", 5, 0x80}, {"0x1001 Read Local Version", 14, 0x08},
        {"0x1002 Read Supported Commands", 14, 0x10}, {"0x1003 Read Local Features", 14, 0x20},
        {"0x1004 Read Local Extended Features", 14, 0x40}, {"0x1005 Read Buffer Size", 14, 0x80},
        {"0x1009 Read BD_ADDR", 15, 0x02}, {"0x0C01 Set Event Mask", 5, 0x40},
        {"0x0C63 Set Event Mask Page 2", 22, 0x04}, {"0x2001 LE Set Event Mask", 25, 0x01},
        {"0x2003 LE Read Local Supported Features", 25, 0x04}, {"0x0C56 Write Simple Pairing Mode", 17, 0x40},
        {"0x0C6D Write LE Host Supported (fix)", 24, 0x40},
        {"0x2002 LE Read Buffer Size V1", 25, 0x02}, {"0x201C LE Read Supported States", 28, 0x08},
        {"0x200F LE Read Filter Accept List Size (fix)", 26, 0x40},
        {"0x0C33 Host Buffer Size", 10, 0x40},
        {"0x0C31 Host Flow Control (fix)", 10, 0x20},
        {"0x0C5B Write Erroneous Data Reporting (fix)", 18, 0x08},
        {"0x2060 LE Read Buffer Size V2 (fix)", 41, 0x20},
        {"0x0C13 Write Local Name (fix, post-init)", 7, 0x01},
        {"0x0C14 Read Local Name (fix, post-init)", 7, 0x02},
        {"0x0C52 Write Extended Inquiry Response (fix, post-init)", 17, 0x02},
    };
    for (size_t i = 0; i < sizeof pass_gates / sizeof pass_gates[0]; i++) {
        char lbl[96];
        snprintf(lbl, sizeof lbl, "gate SET: %s", pass_gates[i].name);
        check(lbl, (mask[pass_gates[i].octet] & pass_gates[i].bit) != 0, 1);
    }
    /* Steps that must stay gated: the core does not serve them with
     * correct semantics for this personality, and the guest either skips
     * them on the served feature values or tolerates the 628 locally. */
    static const struct { const char *name; int octet; int bit; } clear_gates[] = {
        {"0x2087 LE Read All Local Supported Features", 47, 0x04},
        {"0x202F LE Read Maximum Data Length", 35, 0x08},
        {"0x2074 LE Set Host Feature", 44, 0x02},
        {"0x207D LE Set Default Subrate", 46, 0x01},
        {"0x20A2 LE Set Default Rate Parameters", 29, 0x10},
        {"0x0409 Create Connection (refused by design)", 0, 0x10},
    };
    for (size_t i = 0; i < sizeof clear_gates / sizeof clear_gates[0]; i++) {
        char lbl[96];
        snprintf(lbl, sizeof lbl, "gate CLEAR: %s", clear_gates[i].name);
        check(lbl, (mask[clear_gates[i].octet] & clear_gates[i].bit) != 0, 0);
    }

    /* ---- extfeat flow, preserved: BD_ADDR / Features / 0x1004 ---- */
    printf("scenario: BD_ADDR and Local Supported Features complete the five\n");
    static const uint8_t addr_cmd[3] = {0x09, 0x10, 0x00};
    drive("Read BD_ADDR", addr_cmd, 3, 0x1009, 12);

    static const uint8_t feat_cmd[3] = {0x03, 0x10, 0x00};
    drive("Read Local Supported Features", feat_cmd, 3, 0x1003, 14);
    check("features byte 7 = 0x87 (Extended Features bit set)", ev[6 + 7], 0x87);
    /* LMP features byte 4 (ev[6+4]) bit 6 is LE Supported (Controller):
     * the guest derives its cached LE flag from it; it gates every LE
     * step of the sequence. */
    check("features byte 4 bit 6 set (LE Supported, Controller)", (ev[6 + 4] & 0x40) != 0, 1);

    printf("scenario: 0x1004 page 2, the exact command the guest's init issues\n");
    static const uint8_t ext2_cmd[4] = {0x04, 0x10, 0x01, 0x02};
    drive("Read Local Extended Features p2", ext2_cmd, 4, 0x1004, 16);
    check("extfeat event code 0x0E", ev[0], 0x0e);
    check("extfeat plen byte 14 (4 + 10)", ev[1], 14);
    check("extfeat Page_Number echoes the request (2)", ev[6], 2);
    check("extfeat Maximum_Page_Number 2", ev[7], 2);
    long p2_nonzero = 0;
    for (int i = 0; i < 8; i++) p2_nonzero |= ev[8 + i];
    check("extfeat page 2 features carry no bits", p2_nonzero, 0);

    printf("scenario: 0x1004 pages 0 and 1\n");
    static const uint8_t ext0_cmd[4] = {0x04, 0x10, 0x01, 0x00};
    drive("0x1004 page 0", ext0_cmd, 4, 0x1004, 16);
    check("page 0 echo", ev[6], 0);
    long p0_nonzero = 0;
    for (int i = 0; i < 8; i++) p0_nonzero |= ev[8 + i];
    check("page 0 features carry no bits beyond the 0x1003 page", p0_nonzero, 0);

    static const uint8_t ext1_cmd[4] = {0x04, 0x10, 0x01, 0x01};
    drive("0x1004 page 1", ext1_cmd, 4, 0x1004, 16);
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

    /* ---- the rest of the chain, in guest order, real plens ---- */
    printf("scenario: chain continues, LE features branch (0x2003 taken)\n");
    static const uint8_t lefeat_cmd[3] = {0x03, 0x20, 0x00};
    drive("LE Read Local Supported Features", lefeat_cmd, 3, 0x2003, 14);
    check("LE features byte 0 = 0x03", ev[6], 0x03);
    /* LE features byte 3 is the guest's V1/V2 buffer-size selector
     * (>= 0x10 selects V2): the served value keeps the V1 branch. */
    check("LE features byte 3 = 0 (V1 buffer-size branch selected)", ev[9], 0);
    long lefeat_rest = 0;
    for (int i = 1; i < 8; i++) lefeat_rest |= ev[6 + i];
    check("LE features bytes 1..7 zero (feature steps below stay skipped)", lefeat_rest, 0);

    printf("scenario: mask programming writes, plen 8 / 8 / 8\n");
    static const uint8_t sem_cmd[11] = {0x01, 0x0c, 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    drive("Set Event Mask", sem_cmd, 11, 0x0c01, 6);
    static const uint8_t sem2_cmd[11] = {0x63, 0x0c, 0x08, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    drive("Set Event Mask Page 2", sem2_cmd, 11, 0x0c63, 6);
    static const uint8_t lesem_cmd[11] = {0x01, 0x20, 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    drive("LE Set Event Mask", lesem_cmd, 11, 0x2001, 6);

    printf("scenario: 0x0C56 (plen 1) and 0x0C6D (plen 2, the fatal step)\n");
    static const uint8_t ssp_cmd[4] = {0x56, 0x0c, 0x01, 0x01};
    drive("Write Simple Pairing Mode", ssp_cmd, 4, 0x0c56, 6);
    static const uint8_t lehost_cmd[5] = {0x6d, 0x0c, 0x02, 0x01, 0x01};
    drive("Write LE Host Supported", lehost_cmd, 5, 0x0c6d, 6);

    printf("scenario: LE Read Buffer Size V1 (plen 0), the branch taken\n");
    static const uint8_t lebuf_cmd[3] = {0x02, 0x20, 0x00};
    drive("LE Read Buffer Size V1", lebuf_cmd, 3, 0x2002, 9);
    check("V1 LE ACL length 251", ev[6] | ev[7] << 8, 251);
    check("V1 LE ACL packets 8", ev[8], 8);

    printf("scenario: LE Read Supported States and Filter Accept List Size\n");
    static const uint8_t states_cmd[3] = {0x1c, 0x20, 0x00};
    drive("LE Read Supported States", states_cmd, 3, 0x201c, 14);
    check("states word 0 = 0xFFFFFFFF", (long)(ev[6] | ev[7] << 8 | ev[8] << 16 | (uint32_t)ev[9] << 24), (long)0xffffffff);
    static const uint8_t fals_cmd[3] = {0x0f, 0x20, 0x00};
    drive("LE Read Filter Accept List Size", fals_cmd, 3, 0x200f, 7);
    check("accept list size payload 16 (parser needs 1 byte)", ev[6], 0x10);

    printf("scenario: 0x1005 Read Buffer Size (raw-status chain step)\n");
    static const uint8_t bufsize_cmd[3] = {0x05, 0x10, 0x00};
    drive("Read Buffer Size", bufsize_cmd, 3, 0x1005, 13);
    check("buffer size ACL length 1021", ev[6] | ev[7] << 8, 1021);
    check("buffer size SCO length 64", ev[8], 64);
    check("buffer size ACL packets 4", ev[9] | ev[10] << 8, 4);
    check("buffer size SCO packets 4", ev[11] | ev[12] << 8, 4);

    printf("scenario: host buffer/flow writes, plen 7 / 1, and 0x0C5B plen 1\n");
    static const uint8_t hbs_cmd[10] = {0x33, 0x0c, 0x07, 0xfd, 0x03, 0x40, 0x04, 0x00, 0x04, 0x00};
    drive("Host Buffer Size", hbs_cmd, 10, 0x0c33, 6);
    static const uint8_t hfc_cmd[4] = {0x31, 0x0c, 0x01, 0x01};
    drive("Set Host Controller To Host Flow Control", hfc_cmd, 4, 0x0c31, 6);
    static const uint8_t edr_cmd[4] = {0x5b, 0x0c, 0x01, 0x01};
    drive("Write Default Erroneous Data Reporting", edr_cmd, 4, 0x0c5b, 6);

    printf("scenario: LE Read Buffer Size V2 (plen 0)\n");
    static const uint8_t lebuf2_cmd[3] = {0x60, 0x20, 0x00};
    drive("LE Read Buffer Size V2", lebuf2_cmd, 3, 0x2060, 12);
    check("V2 plen byte 10 (4 + 6, parser needs 6 after status)", ev[1], 10);
    check("V2 LE ACL length 251 (matches V1)", ev[6] | ev[7] << 8, 251);
    check("V2 LE ACL packets 8 (matches V1)", ev[8], 8);
    check("V2 LE ISO length 0 (no ISO datapath)", ev[9] | ev[10] << 8, 0);
    check("V2 LE ISO packets 0", ev[11], 0);

    printf("test_bt_hci_initseq: %d checks, %d failures\n", checks, failures);
    printf("%s\n", failures == 0 ? "INITSEQ SCENARIO PASS" : "INITSEQ SCENARIO FAIL");
    return failures != 0;
}
