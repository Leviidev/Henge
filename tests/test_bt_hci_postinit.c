/* Certification test: FULL POST-INIT alignment + the scan
 * residuals (disco state sync + LE extended scan) + the LE
 * EXTENDED ADVERTISING family modeled per-set.
 *
 * An earlier version of this harness certified the name + EIR steps of the
 * Server.Core post-init chain; a guest boot then died one step later, inside the
 * EIR completion callback itself, on Write Class of Device 0x0C24. This
 * version replays the COMPLETE post-init table:
 *
 *   Chain S (Server.Core, invoker-driven): the 14-step DEVMGR
 *     static-settings sequence (all 628-tolerated, bits stay CLEAR),
 *     Write Local Name 0x0C13, Write EIR 0x0C52, Write Class of Device
 *     0x0C24 (desc 0x51, octet 9 bit 0x02, plen 3: the fatal step, its
 *     synchronous return is tested by the EIR completion callback
 *     0x1005a17ec and any nonzero invokes the registered fatal handler).
 *   Chain S tail (non-HCI): the two SECMGR registrations in the same
 *     callback; RegisterESE is proven to return 0 from the compiled-in
 *     descriptor, RegisterSecurityDB carries a named residual risk in
 *     carries a named residual risk (no HCI involvement, nothing to replay here).
 *   Chain D (DEVMGR config advancer): Read Local Name 0x0C14 (real
 *     shaped case), the conditional Change Local Name (name non-empty
 *     on this core, branch not taken), the conditional second Write
 *     EIR (same claim as Chain S).
 *   Disco application: Write Scan Enable 0x0C1A (desc 0x47, octet 7
 *     bit 0x80, plen 1) CLAIMED (deliberate expectation change
 *     vs the earlier harness, where it replayed CLEAR as "logged and dropped"): a pure
 *     write with a bookkeeping-only completion callback; unclaimed,
 *     the guest can never become connectable at the HCI level.
 *     Read Scan Enable 0x0C19 CLAIMED with the shaped reply:
 *     the core tracks the scan register (power-on 0x00, replaced by
 *     every 0x0C1A write, cleared by HCI Reset) and answers status +
 *     exactly that byte; replayed below across a write-read sequence
 *     including the reset default. A guest boot proved the clear bit aborted
 *     both discoverability appliers before 0x0C1A was ever issued.
 *     Write Current IAC LAP 0x0C3A (desc 0x64, octet 11 bit 0x10)
 *     CLAIMED: it is the disco policy applier's FIRST step and
 *     its synchronous 628 aborted the whole WriteDiscoverability
 *     application before the read was reached; a pure write served
 *     by the default success, driven below at real plen.
 *   LE extended scan (Option A): LE Set Extended Scan
 *     Parameters 0x2041 (desc 0xD7, octet 37 bit 0x20) and LE Set
 *     Extended Scan Enable 0x2042 (desc 0xD8, octet 37 bit 0x40)
 *     CLAIMED: the daemon's LE layer selects the extended setters
 *     from its internal capability cache, and a guest boot logged 25 scan
 *     starts refused at the unclaimed params step. 0x2041 is a pure
 *     parameter state write (default success, as classic 0x200B);
 *     0x2042 tracks le_scan_enabled from its Enable byte, driven
 *     below at real plen 6 with the tracked state asserted.
 *   Discovery frontier: Inquiry 0x0401 (desc 0x00, octet 0 bit 0x01,
 *     long claimed, real core case: Command Status then
 *     Inquiry Complete with no results) replayed end-to-end, and
 *     Inquiry Cancel 0x0402 (desc 0x01, octet 0 bit 0x02, plen 0)
 *     CLAIMED so the inquiry state machine cancel path
 *     completes like silicon.
 *   Event-driven DEVMGR setters replayed CLEAR by design: 0x080D
 *   (desc 0x31, log-only failure), 0x0C37 Write Link Supervision
 *   Timeout (desc 0x61, log-only).
 *
 * Drives use the guest's real 21 00 form at real plen through the real
 * TRB path, including the chained-TRB Write Local Name scenario.
 *
 * On the pre-scan-fix code this harness fails with exactly the scan-fix defect
 * signature: whole-octet 7 reads 0x83 not 0xC3, octet 11 reads 0x00
 * not 0x10, octet 37 reads 0x00 not 0x60, the 0x0C19 / 0x0C3A /
 * 0x2041 / 0x2042 pass-gates read clear, the 0x0C19 drive returns
 * the unshaped 6-byte default Command Complete (no payload byte)
 * instead of the shaped 7, every scan-byte sequence assertion fails
 * (no register exists to track), and the 0x2042 drives complete but
 * le_scan_enabled never moves, which the two state assertions
 * capture: the gate refusal and the missing state are guest-visible
 * arithmetic, which is what these checks capture.
 * Extended advertising: the whole setter/reader family is
 * replayed at real plen through the real TRB path against the core's
 * tracked per-set model: LE Read Maximum Advertising Data Length
 * 0x203A (status + uint16 1650, the shape callback 0x100227ec4
 * consumes by value), LE Read Number of Supported Advertising Sets
 * 0x203B (status + the 1-byte capacity), LE Set Extended Advertising
 * Parameters 0x2036 (fixed plen 25; completion status + the 1
 * Selected_TX_Power byte callback 0x10022a2e4 appends as AD type
 * 0x0A; 0x7F request selects 0 dBm, a concrete request is selected
 * verbatim), LE Set Advertising Set Random Address 0x2035 (plen 7),
 * advertising data (0x2037) and scan response data (0x2038) stored
 * verbatim per set with fragment assembly (First / Intermediate /
 * Last / Complete) across three wire commands, LE Set Extended
 * Advertising Enable 0x2039 (per-set entries and the Number_of_Sets
 * 0 all-sets form, duration / max-events stored), LE Remove
 * Advertising Set 0x203C and LE Clear Advertising Sets 0x203D
 * lifecycle (a removed set rejects further data with the spec error
 * 0x42), the periodic trio 0x203E (plen 7) / 0x203F (fragmented
 * data shape without the fragment-preference byte) / 0x2040
 * (plen 2), the capacity error (9th distinct set -> 0x07), and HCI
 * Reset clearing the model. Octet 36 -> 0xFE and octet 37 -> 0x7F
 * are deliberate claim changes vs the scan-fix state, annotated here;
 * octet 36 bit 0x01 (LE Transmitter Test v2
 * 0x2034, an RF test mode) and octet 37 bit 0x80 (LE Extended
 * Create Connection 0x2043) stay CLEAR by named disposition.
 *
 * On the pre-advertising code this harness fails with exactly the advertising defect
 * signature: whole-octet 36 reads 0x00 not 0xFE, octet 37 reads
 * 0x60 not 0x7F, the twelve family pass-gates read clear, the
 * 0x203A / 0x203B / 0x2036 drives return the unshaped 6-byte
 * default Command Complete instead of 8 / 7 / 7, every adv_sets
 * state assertion reads zero (no model exists), the error-path
 * drives return status 0 where 0x42 / 0x07 are expected, and
 * le_advertising_enabled never moves on 0x2039. No check outside
 * the advertising surface moves.
 * Build (per tree): clang -std=c11 -Wall -Wextra -O2 -g -Icore -Ihost
 *   -Idevices tests/test_bt_hci_postinit.c <ENGINE+DEV objects except
 *   xhci.o> <METAL_LIBS> -o test_bt_hci_postinit  (the xhci-suite build pattern).
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

/* One OUT control transfer whose data stage is split into two Data
 * TRBs: the first carries the CHAIN bit, the second is the unchained
 * tail. Mirrors a guest that segments a long data stage. */
static void ep0_transfer_chained(HvXhci *x, const uint8_t setup[8], uint64_t data_pa,
                                 uint32_t first_len, uint32_t second_len) {
    clear_ring(EP0_PA);
    x->bep[1].dequeue = EP0_PA;
    x->bep[1].ccs = 1;
    x->bep_running[1] = 1;
    uint64_t sp = (uint64_t)setup[0] | (uint64_t)setup[1] << 8 | (uint64_t)setup[2] << 16 |
                  (uint64_t)setup[3] << 24 | (uint64_t)setup[4] << 32 | (uint64_t)setup[5] << 40 |
                  (uint64_t)setup[6] << 48 | (uint64_t)setup[7] << 56;
    int i = 0;
    put_trb(EP0_PA, i++, sp, setup[6] | (uint32_t)setup[7] << 8,
            (uint32_t)TRB_SETUP << 10 | 2u << 16);
    put_trb(EP0_PA, i++, data_pa, first_len,
            (uint32_t)TRB_DATA << 10 | 1u << 4 /* CHAIN */);
    put_trb(EP0_PA, i++, data_pa + first_len, second_len,
            (uint32_t)TRB_DATA << 10);
    put_trb(EP0_PA, i++, 0, 0, (uint32_t)TRB_STATUS << 10 | 1u << 16);
    run_ep0_bt(x, BT_SLOT);
}

static uint32_t poll_event(HvXhci *x, uint8_t *out, uint32_t cap) {
    uint8_t z[512] = {0};
    hv_phys_write(&m, EVTBUF_PA, z, sizeof z);
    clear_ring(EVT_PA);
    x->bep[BT_DCI_EVT].dequeue = EVT_PA;
    x->bep[BT_DCI_EVT].ccs = 1;
    x->bep_running[BT_DCI_EVT] = 1;
    put_trb(EVT_PA, 0, EVTBUF_PA, 512, (uint32_t)TRB_NORMAL << 10);
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
static uint8_t ev[512];

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

static uint32_t drive_st(const char *name, const uint8_t *cmd, uint32_t len,
                         uint16_t opcode, long want_status) {
    char lbl[96];
    send21(x, cmd, len);
    snprintf(lbl, sizeof lbl, "core saw %s", name);
    check(lbl, (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    uint32_t n = poll_event(x, ev, sizeof ev);
    snprintf(lbl, sizeof lbl, "%s CC len", name);
    check(lbl, (long)n, 6);
    snprintf(lbl, sizeof lbl, "%s CC opcode echo", name);
    check(lbl, ev[3] | ev[4] << 8, opcode);
    snprintf(lbl, sizeof lbl, "%s CC status", name);
    check(lbl, ev[5], want_status);
    return n;
}

static HvBtAdvSet *adv_get(int handle) {
    for (int i = 0; i < HV_BT_MAX_ADV_SETS; i++)
        if (x->bt.adv_sets[i].in_use && x->bt.adv_sets[i].handle == handle)
            return &x->bt.adv_sets[i];
    return NULL;
}
static long adv_count(void) {
    long n = 0;
    for (int i = 0; i < HV_BT_MAX_ADV_SETS; i++)
        if (x->bt.adv_sets[i].in_use) n++;
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

    printf("scenario: SET_CONFIGURATION 1 on the modeled dongle\n");
    static const uint8_t setcfg[8] = {0x00, 0x09, 0x01, 0x00, 0, 0, 0, 0};
    ep0_transfer(x, setcfg, 0, 0, 0);
    check("bt_configured is 1 after SET_CONFIGURATION", x->bt_configured, 1);

    /* ---- the served mask, read back over the wire ---- */
    printf("scenario: Read Local Supported Commands, full post-init gate replay\n");
    static const uint8_t mask_cmd[3] = {0x02, 0x10, 0x00};
    drive("Read Local Supported Commands", mask_cmd, 3, 0x1002, 70);
    const uint8_t *mask = ev + 6;
    check("mask octet 0 = 0x23 (Inquiry + Inquiry Cancel + Disconnect claimed)", mask[0], 0x23);
    check("mask octet 7 = 0xC3 (name pair + Write Scan Enable + Read Scan Enable)", mask[7], 0xc3);
    check("mask octet 11 = 0x10 (Write Current IAC LAP claimed, disco policy head)", mask[11], 0x10);
    check("mask octet 37 = 0x7F (scan pair + periodic/remove/clear family claimed)", mask[37], 0x7f);
    check("mask octet 36 = 0xFE (extended advertising family claimed, 0x2034 test mode clear)", mask[36], 0xfe);
    check("mask octet 9 = 0x02 (Write Class of Device claimed, fix)", mask[9], 0x02);
    check("mask octet 17 = 0x42 (Write EIR claimed over the prior 0x40)", mask[17], 0x42);

    /* Bits the post-init chains cannot survive losing (CBCrash class)
     * plus the functional claims (pure writes, bookkeeping-only
     * completions): a synchronous 628 must never occur for these. */
    static const struct { const char *name; int octet; int bit; } pass_gates[] = {
        {"0x0C13 Write Local Name (fix)", 7, 0x01},
        {"0x0C14 Read Local Name (fix)", 7, 0x02},
        {"0x0C52 Write Extended Inquiry Response (fix)", 17, 0x02},
        {"0x0C24 Write Class of Device (fix, the fatal step)", 9, 0x02},
        {"0x0C1A Write Scan Enable (claim, disco application)", 7, 0x80},
        {"0x0C19 Read Scan Enable (claim, disco state sync, shaped reply)", 7, 0x40},
        {"0x0C3A Write Current IAC LAP (claim, disco policy applier head)", 11, 0x10},
        {"0x2041 LE Set Extended Scan Parameters (claim, Option A)", 37, 0x20},
        {"0x2042 LE Set Extended Scan Enable (claim, Option A)", 37, 0x40},
        {"0x0401 Inquiry (long claimed, real case)", 0, 0x01},
        {"0x0402 Inquiry Cancel (claim, discovery state machine)", 0, 0x02},
        {"0x2035 LE Set Advertising Set Random Address (claim)", 36, 0x02},
        {"0x2036 LE Set Extended Advertising Parameters (claim, shaped return)", 36, 0x04},
        {"0x2037 LE Set Extended Advertising Data (claim)", 36, 0x08},
        {"0x2038 LE Set Extended Advertising Scan Response Data (claim)", 36, 0x10},
        {"0x2039 LE Set Extended Advertising Enable (claim)", 36, 0x20},
        {"0x203A LE Read Maximum Advertising Data Length (claim, shaped return)", 36, 0x40},
        {"0x203B LE Read Number of Supported Advertising Sets (claim, shaped return)", 36, 0x80},
        {"0x203C LE Remove Advertising Set (claim)", 37, 0x01},
        {"0x203D LE Clear Advertising Sets (claim)", 37, 0x02},
        {"0x203E LE Set Periodic Advertising Parameters (claim)", 37, 0x04},
        {"0x203F LE Set Periodic Advertising Data (claim)", 37, 0x08},
        {"0x2040 LE Set Periodic Advertising Enable (claim)", 37, 0x10},
    };
    for (size_t i = 0; i < sizeof pass_gates / sizeof pass_gates[0]; i++) {
        char lbl[96];
        snprintf(lbl, sizeof lbl, "gate SET: %s", pass_gates[i].name);
        check(lbl, (mask[pass_gates[i].octet] & pass_gates[i].bit) != 0, 1);
    }
    /* Operations whose synchronous 628 the daemon provably absorbs
     * (tolerated sequence steps, logged-and-dropped disco reads and
     * event-driven setters) stay clear by design: claiming them would
     * change nothing the guest can observe, and the mask stays
     * minimal. 0x0C1A left this list with the post-init claims; 0x0C19 and 0x0C3A
     * left it with the scan claims (see header). */
    static const struct { const char *name; int octet; int bit; } clear_gates[] = {
        {"0x080F Write Default Link Policy Settings (tolerated)", 5, 0x10},
        {"0x0C16 Write Connection Accept Timeout (tolerated)", 7, 0x08},
        {"0x0C18 Write Page Timeout (tolerated)", 7, 0x20},
        {"0x0C1C Write Page Scan Activity (tolerated)", 8, 0x02},
        {"0x0C1E Write Inquiry Scan Activity (tolerated)", 8, 0x08},
        {"0x0C26 Write Voice Setting (tolerated)", 9, 0x08},
        {"0x0C2A Write Num Broadcast Retransmissions (tolerated)", 9, 0x80},
        {"0x0C2C Write Hold Mode Activity (tolerated)", 10, 0x02},
        {"0x0C2F Write SCO Flow Control Enable (tolerated)", 10, 0x10},
        {"0x0C3C Write Page Scan Period Mode (tolerated)", 11, 0x40},
        {"0x0C43 Write Inquiry Scan Type (tolerated)", 12, 0x20},
        {"0x0C45 Write Inquiry Mode (tolerated)", 12, 0x80},
        {"0x0C47 Write Page Scan Type (tolerated)", 13, 0x02},
        {"0x0C49 Write AFH Channel Assessment Mode (tolerated)", 13, 0x08},
        {"0x080D link-settings write (event-driven, log-only failure)", 5, 0x04},
        {"0x0C37 Write Link Supervision Timeout setter (log-only failure)", 11, 0x02},
        {"0x2034 LE Transmitter Test v2 (RF test mode, not advertising; disposition)", 36, 0x01},
        {"0x2043 LE Extended Create Connection (initiating, would fabricate a peer; disposition)", 37, 0x80},
    };
    for (size_t i = 0; i < sizeof clear_gates / sizeof clear_gates[0]; i++) {
        char lbl[96];
        snprintf(lbl, sizeof lbl, "gate CLEAR: %s", clear_gates[i].name);
        check(lbl, (mask[clear_gates[i].octet] & clear_gates[i].bit) != 0, 0);
    }

    /* ---- 0x0C19 before any write: the power-on default ---- */
    printf("scenario: Read Scan Enable before any write (power-on default 0x00)\n");
    static const uint8_t readscan_cmd[3] = {0x19, 0x0c, 0x00};
    drive("Read Scan Enable (initial)", readscan_cmd, 3, 0x0c19, 7);
    check("initial scan byte is the power-on default 0x00", ev[6], 0x00);

    /* ---- 0x0C13 at real plen through the real TRB path ---- */
    printf("scenario: Write Local Name, plen 248, single Data TRB (wLength 251)\n");
    uint8_t name_cmd[251];
    name_cmd[0] = 0x13; name_cmd[1] = 0x0c; name_cmd[2] = 248;
    memset(name_cmd + 3, 0, 248);
    memcpy(name_cmd + 3, "Test Computer Name", 18);
    drive("Write Local Name (single TRB)", name_cmd, 251, 0x0c13, 6);

    printf("scenario: Write Local Name, plen 248, chained Data TRBs (128 + 123)\n");
    hv_phys_write(&m, CMDBUF_PA, name_cmd, sizeof name_cmd);
    {
        uint8_t setup[8] = {0x21, 0x00, 0, 0, 0, 0, 251, 0};
        ep0_transfer_chained(x, setup, CMDBUF_PA, 128, 123);
    }
    check("core saw the chained Write Local Name exactly once", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    {
        uint32_t n = poll_event(x, ev, sizeof ev);
        check("chained Write Local Name CC len", (long)n, 6);
        check("chained Write Local Name CC opcode echo", ev[3] | ev[4] << 8, 0x0c13);
        check("chained Write Local Name CC status 0", ev[5], 0);
        check("no second event from the fragments", hv_bt_event_pending(&x->bt), 0);
    }

    /* ---- 0x0C14: the parser-shaped read ---- */
    printf("scenario: Read Local Name, plen 0, full 248-byte name field\n");
    static const uint8_t readname_cmd[3] = {0x14, 0x0c, 0x00};
    drive("Read Local Name", readname_cmd, 3, 0x0c14, 254);
    check("read name CC plen byte 252 (4 + 248)", ev[1], 252);
    check("read name field starts with the served name", memcmp(ev + 6, "BCM20702A0", 10), 0);
    check("read name field NUL at index 10", ev[6 + 10], 0);
    long tail = 0;
    for (int i = 11; i < 248; i++) tail |= ev[6 + i];
    check("read name field zero padded to 248", tail, 0);

    /* ---- 0x0C52 at real plen ---- */
    printf("scenario: Write Extended Inquiry Response, plen 241 (wLength 244)\n");
    uint8_t eir_cmd[244];
    eir_cmd[0] = 0x52; eir_cmd[1] = 0x0c; eir_cmd[2] = 241;
    memset(eir_cmd + 3, 0, 241);
    eir_cmd[3] = 1; /* FEC_Required */
    eir_cmd[4] = 11; eir_cmd[5] = 0x09; /* EIR field: len 11, type Complete Name */
    memcpy(eir_cmd + 6, "BCM20702A0", 10);
    drive("Write Extended Inquiry Response", eir_cmd, 244, 0x0c52, 6);

    /* ---- 0x0C24: the fatal step, at real plen ---- */
    printf("scenario: Write Class of Device, plen 3 (wLength 6)\n");
    static const uint8_t cod_cmd[6] = {0x24, 0x0c, 0x03, 0x24, 0x04, 0x00};
    drive("Write Class of Device", cod_cmd, 6, 0x0c24, 6);

    /* ---- 0x0C1A: disco application write ---- */
    printf("scenario: Write Scan Enable, plen 1 (wLength 4)\n");
    static const uint8_t scan_cmd[4] = {0x1a, 0x0c, 0x01, 0x03};
    drive("Write Scan Enable", scan_cmd, 4, 0x0c1a, 6);

    /* ---- the disco sync sequence: write, read back, rewrite ---- */
    printf("scenario: Read Scan Enable after Write Scan Enable 0x03\n");
    drive("Read Scan Enable (after 0x03)", readscan_cmd, 3, 0x0c19, 7);
    check("scan byte reads back the written 0x03", ev[6], 0x03);

    printf("scenario: Write Scan Enable 0x00, read back\n");
    static const uint8_t scan0_cmd[4] = {0x1a, 0x0c, 0x01, 0x00};
    drive("Write Scan Enable 0x00", scan0_cmd, 4, 0x0c1a, 6);
    drive("Read Scan Enable (after 0x00)", readscan_cmd, 3, 0x0c19, 7);
    check("scan byte reads back the written 0x00", ev[6], 0x00);

    printf("scenario: Write Scan Enable 0x02, HCI Reset, read back the reset default\n");
    static const uint8_t scan2_cmd[4] = {0x1a, 0x0c, 0x01, 0x02};
    drive("Write Scan Enable 0x02", scan2_cmd, 4, 0x0c1a, 6);
    static const uint8_t reset_cmd[3] = {0x03, 0x0c, 0x00};
    drive("HCI Reset", reset_cmd, 3, 0x0c03, 6);
    drive("Read Scan Enable (after reset)", readscan_cmd, 3, 0x0c19, 7);
    check("scan byte is the reset default 0x00 after HCI Reset", ev[6], 0x00);

    /* ---- 0x0C3A: the disco policy applier's first step ---- */
    printf("scenario: Write Current IAC LAP, plen 4 (Num_Current_IAC 1 + GIAC)\n");
    static const uint8_t iac_cmd[7] = {0x3a, 0x0c, 0x04, 0x01, 0x33, 0x8b, 0x9e};
    drive("Write Current IAC LAP", iac_cmd, 7, 0x0c3a, 6);

    /* ---- LE extended scan setters (Option A) ---- */
    printf("scenario: LE Set Extended Scan Parameters, plen 8 (1 PHY)\n");
    static const uint8_t extpar_cmd[11] = {0x41, 0x20, 0x08, 0x00, 0x00, 0x01,
                                           0x01, 0x30, 0x00, 0x12, 0x00};
    drive("LE Set Extended Scan Parameters", extpar_cmd, 11, 0x2041, 6);

    printf("scenario: LE Set Extended Scan Enable, plen 6, enable then disable\n");
    static const uint8_t exten1_cmd[9] = {0x42, 0x20, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00};
    drive("LE Set Extended Scan Enable (enable)", exten1_cmd, 9, 0x2042, 6);
    check("le_scan_enabled is 1 after the extended enable", x->bt.le_scan_enabled, 1);
    static const uint8_t exten0_cmd[9] = {0x42, 0x20, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    drive("LE Set Extended Scan Enable (disable)", exten0_cmd, 9, 0x2042, 6);
    check("le_scan_enabled is 0 after the extended disable", x->bt.le_scan_enabled, 0);

    /* ---- discovery frontier ---- */
    printf("scenario: Inquiry Cancel, plen 0\n");
    static const uint8_t cancel_cmd[3] = {0x02, 0x04, 0x00};
    drive("Inquiry Cancel", cancel_cmd, 3, 0x0402, 6);

    printf("scenario: Inquiry, plen 5: Command Status then Inquiry Complete\n");
    static const uint8_t inq_cmd[8] = {0x01, 0x04, 0x05, 0x33, 0x8b, 0x9e, 0x00, 0x00};
    send21(x, inq_cmd, sizeof inq_cmd);
    check("core saw Inquiry", (long)x->bt.commands_seen, ++seen);
    memset(ev, 0, sizeof ev);
    {
        uint32_t n = poll_event(x, ev, sizeof ev);
        check("Inquiry first event len (Command Status)", (long)n, 6);
        check("Inquiry first event code 0x0f (Command Status)", ev[0], 0x0f);
        check("Inquiry Command Status status byte 0", ev[2], 0);
        check("Inquiry Command Status opcode echo", ev[4] | ev[5] << 8, 0x0401);
    }
    memset(ev, 0, sizeof ev);
    {
        uint32_t n = poll_event(x, ev, sizeof ev);
        check("Inquiry second event len (Inquiry Complete)", (long)n, 3);
        check("Inquiry second event code 0x01 (Inquiry Complete)", ev[0], 0x01);
        check("Inquiry Complete status 0", ev[2], 0);
        check("no third event from Inquiry", hv_bt_event_pending(&x->bt), 0);
    }


    /* ---- LE extended advertising family, per-set model ---- */
    {
        printf("scenario: Read Maximum Advertising Data Length, plen 0, shaped uint16 return\n");
        static const uint8_t maxlen_cmd[3] = {0x3a, 0x20, 0x00};
        drive("LE Read Maximum Advertising Data Length", maxlen_cmd, 3, 0x203a, 8);
        check("max advertising data length low byte 0x72 (1650)", ev[6], 0x72);
        check("max advertising data length high byte 0x06 (1650)", ev[7], 0x06);

        printf("scenario: Read Number of Supported Advertising Sets, plen 0, shaped 1-byte return\n");
        static const uint8_t nsets_cmd[3] = {0x3b, 0x20, 0x00};
        drive("LE Read Number of Supported Advertising Sets", nsets_cmd, 3, 0x203b, 7);
        check("supported advertising sets byte is the model capacity 8", ev[6], 8);

        printf("scenario: Set Extended Advertising Parameters, plen 25, handle 0, TX 0x7F\n");
        static const uint8_t p36_cmd[28] = {0x36, 0x20, 25,
            0x00,             /* handle 0 */
            0x13, 0x00,       /* event properties */
            0x30, 0x00, 0x00, /* interval min 0x30 */
            0x60, 0x00, 0x00, /* interval max 0x60 */
            0x07,             /* channel map */
            0x00, 0x00,       /* own / peer addr type */
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, /* peer addr */
            0x00,             /* filter policy */
            0x7f,             /* TX power: no preference */
            0x01, 0x00, 0x02, /* primary PHY, skip, secondary PHY */
            0x05,             /* SID 5 */
            0x00};            /* scan request notifications off */
        drive("LE Set Extended Advertising Parameters (h0)", p36_cmd, 28, 0x2036, 7);
        check("selected TX power byte is 0 dBm for the 0x7F request", ev[6], 0x00);
        check("adv set 0 exists after params", adv_get(0) != NULL, 1);
        check("adv set 0 SID stored", adv_get(0) ? adv_get(0)->sid : -1, 5);
        check("adv set 0 interval min stored", adv_get(0) ? (long)adv_get(0)->interval_min : -1, 0x30);
        check("adv set 0 interval max stored", adv_get(0) ? (long)adv_get(0)->interval_max : -1, 0x60);

        printf("scenario: Set Extended Advertising Parameters, handle 1, TX -4\n");
        uint8_t p36b_cmd[28];
        memcpy(p36b_cmd, p36_cmd, sizeof p36b_cmd);
        p36b_cmd[3] = 0x01;  /* handle 1 */
        p36b_cmd[22] = 0xfc; /* TX power -4 */
        p36b_cmd[26] = 0x06; /* SID 6 */
        drive("LE Set Extended Advertising Parameters (h1)", p36b_cmd, 28, 0x2036, 7);
        check("selected TX power byte echoes the concrete request -4", ev[6], 0xfc);

        printf("scenario: Set Advertising Set Random Address, plen 7, handle 0\n");
        static const uint8_t rnd_cmd[10] = {0x35, 0x20, 0x07, 0x00, 1, 2, 3, 4, 5, 6};
        drive("LE Set Advertising Set Random Address", rnd_cmd, 10, 0x2035, 6);
        check("adv set 0 random address marked set", adv_get(0) ? adv_get(0)->random_addr_set : -1, 1);
        check("adv set 0 random address stored verbatim", adv_get(0) ? memcmp(adv_get(0)->random_addr, rnd_cmd + 4, 6) : -1, 0);

        printf("scenario: Set Extended Advertising Data, Complete, handle 0\n");
        static const uint8_t data_cmd[12] = {0x37, 0x20, 0x09, 0x00, 0x03, 0x01, 0x05,
                                             'H', 'E', 'L', 'L', 'O'};
        drive("LE Set Extended Advertising Data (complete h0)", data_cmd, 12, 0x2037, 6);
        check("adv set 0 adv data length 5", adv_get(0) ? adv_get(0)->adv_data_len : -1, 5);
        check("adv set 0 adv data stored verbatim", adv_get(0) ? memcmp(adv_get(0)->adv_data, "HELLO", 5) : -1, 0);

        printf("scenario: Set Extended Advertising Data, fragmented, handle 1 (100 + 100 + 50)\n");
        uint8_t frag_cmd[3 + 4 + 100];
        frag_cmd[0] = 0x37; frag_cmd[1] = 0x20; frag_cmd[2] = 104;
        frag_cmd[3] = 0x01; frag_cmd[4] = 0x01; frag_cmd[5] = 0x01; frag_cmd[6] = 100;
        for (int i = 0; i < 100; i++) frag_cmd[7 + i] = (uint8_t)i;
        drive("LE Set Extended Advertising Data (first h1)", frag_cmd, sizeof frag_cmd, 0x2037, 6);
        frag_cmd[4] = 0x00; /* Intermediate */
        drive("LE Set Extended Advertising Data (intermediate h1)", frag_cmd, sizeof frag_cmd, 0x2037, 6);
        frag_cmd[2] = 54; frag_cmd[4] = 0x02; frag_cmd[6] = 50; /* Last, 50 bytes */
        drive("LE Set Extended Advertising Data (last h1)", frag_cmd, 3 + 4 + 50, 0x2037, 6);
        check("adv set 1 assembled adv data length 250", adv_get(1) ? adv_get(1)->adv_data_len : -1, 250);
        check("assembled byte 0 from first fragment", adv_get(1) ? adv_get(1)->adv_data[0] : -1, 0);
        check("assembled byte 99 from first fragment", adv_get(1) ? adv_get(1)->adv_data[99] : -1, 99);
        check("assembled byte 100 from intermediate fragment", adv_get(1) ? adv_get(1)->adv_data[100] : -1, 0);
        check("assembled byte 249 from last fragment", adv_get(1) ? adv_get(1)->adv_data[249] : -1, 49);
        check("adv set 0 data untouched by handle 1 assembly", adv_get(0) ? adv_get(0)->adv_data_len : -1, 5);

        printf("scenario: Set Extended Advertising Scan Response Data, Complete, handle 0\n");
        static const uint8_t scan_cmd[11] = {0x38, 0x20, 0x08, 0x00, 0x03, 0x01, 0x04,
                                             'S', 'C', 'A', 'N'};
        drive("LE Set Extended Advertising Scan Response Data", scan_cmd, 11, 0x2038, 6);
        check("adv set 0 scan response length 4", adv_get(0) ? adv_get(0)->scan_rsp_len : -1, 4);
        check("adv set 0 scan response stored verbatim", adv_get(0) ? memcmp(adv_get(0)->scan_rsp_data, "SCAN", 4) : -1, 0);

        printf("scenario: Set Extended Advertising Enable, per-set entry with duration/events\n");
        static const uint8_t en_cmd[9] = {0x39, 0x20, 0x06, 0x01, 0x01, 0x00, 0x64, 0x00, 0x05};
        drive("LE Set Extended Advertising Enable (h0)", en_cmd, 9, 0x2039, 6);
        check("adv set 0 enabled", adv_get(0) ? adv_get(0)->enabled : -1, 1);
        check("adv set 0 enable duration stored 100", adv_get(0) ? adv_get(0)->enable_duration : -1, 100);
        check("adv set 0 enable max events stored 5", adv_get(0) ? adv_get(0)->enable_max_events : -1, 5);
        check("le_advertising_enabled tracks any enabled set", x->bt.le_advertising_enabled, 1);

        printf("scenario: Set Extended Advertising Enable, disable handle 0\n");
        static const uint8_t dis_cmd[9] = {0x39, 0x20, 0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00};
        drive("LE Set Extended Advertising Enable (disable h0)", dis_cmd, 9, 0x2039, 6);
        check("adv set 0 disabled", adv_get(0) ? adv_get(0)->enabled : -1, 0);
        check("le_advertising_enabled clears when no set is enabled", x->bt.le_advertising_enabled, 0);

        printf("scenario: Set Extended Advertising Enable, Number_of_Sets 0 (all sets)\n");
        static const uint8_t enall_cmd[5] = {0x39, 0x20, 0x02, 0x01, 0x00};
        drive("LE Set Extended Advertising Enable (all)", enall_cmd, 5, 0x2039, 6);
        check("adv set 0 enabled by the all-sets form", adv_get(0) ? adv_get(0)->enabled : -1, 1);
        check("adv set 1 enabled by the all-sets form", adv_get(1) ? adv_get(1)->enabled : -1, 1);
        static const uint8_t disall_cmd[5] = {0x39, 0x20, 0x02, 0x00, 0x00};
        drive("LE Set Extended Advertising Enable (disable all)", disall_cmd, 5, 0x2039, 6);
        check("adv set 0 disabled by the all-sets form", adv_get(0) ? adv_get(0)->enabled : -1, 0);
        check("adv set 1 disabled by the all-sets form", adv_get(1) ? adv_get(1)->enabled : -1, 0);
        check("le_advertising_enabled 0 after disable-all", x->bt.le_advertising_enabled, 0);

        printf("scenario: Set Periodic Advertising Parameters, plen 7, handle 0\n");
        static const uint8_t perpar_cmd[10] = {0x3e, 0x20, 0x07, 0x00, 0x20, 0x00, 0x40, 0x00, 0x00, 0x00};
        drive("LE Set Periodic Advertising Parameters", perpar_cmd, 10, 0x203e, 6);
        check("adv set 0 periodic interval min stored 0x20", adv_get(0) ? adv_get(0)->per_interval_min : -1, 0x20);
        check("adv set 0 periodic interval max stored 0x40", adv_get(0) ? adv_get(0)->per_interval_max : -1, 0x40);

        printf("scenario: Set Periodic Advertising Data, Complete, handle 0\n");
        static const uint8_t perdata_cmd[12] = {0x3f, 0x20, 0x09, 0x00, 0x03, 0x06,
                                                'P', 'E', 'R', 'I', 'O', 'D'};
        drive("LE Set Periodic Advertising Data", perdata_cmd, 12, 0x203f, 6);
        check("adv set 0 periodic data length 6", adv_get(0) ? adv_get(0)->per_data_len : -1, 6);
        check("adv set 0 periodic data stored verbatim", adv_get(0) ? memcmp(adv_get(0)->per_data, "PERIOD", 6) : -1, 0);

        printf("scenario: Set Periodic Advertising Enable, plen 2, handle 0\n");
        static const uint8_t peren_cmd[5] = {0x40, 0x20, 0x02, 0x01, 0x00};
        drive("LE Set Periodic Advertising Enable (on)", peren_cmd, 5, 0x2040, 6);
        check("adv set 0 periodic enabled", adv_get(0) ? adv_get(0)->per_enabled : -1, 1);
        static const uint8_t perdis_cmd[5] = {0x40, 0x20, 0x02, 0x00, 0x00};
        drive("LE Set Periodic Advertising Enable (off)", perdis_cmd, 5, 0x2040, 6);
        check("adv set 0 periodic disabled", adv_get(0) ? adv_get(0)->per_enabled : -1, 0);

        printf("scenario: error paths and Remove lifecycle\n");
        static const uint8_t ghost_cmd[7] = {0x37, 0x20, 0x04, 0x07, 0x03, 0x01, 0x00};
        drive_st("LE Set Extended Advertising Data (nonexistent h7)", ghost_cmd, 7, 0x2037, 0x42);
        static const uint8_t remove_cmd[4] = {0x3c, 0x20, 0x01, 0x01};
        drive("LE Remove Advertising Set (h1)", remove_cmd, 4, 0x203c, 6);
        check("adv set 1 gone after Remove", adv_get(1) == NULL, 1);
        uint8_t ghost2_cmd[7];
        memcpy(ghost2_cmd, ghost_cmd, sizeof ghost2_cmd);
        ghost2_cmd[3] = 0x01; /* the removed handle 1 */
        drive_st("LE Set Extended Advertising Data (removed h1)", ghost2_cmd, 7, 0x2037, 0x42);

        printf("scenario: Clear Advertising Sets, plen 0\n");
        static const uint8_t clear_cmd[3] = {0x3d, 0x20, 0x00};
        drive("LE Clear Advertising Sets", clear_cmd, 3, 0x203d, 6);
        check("no adv sets remain after Clear", adv_count(), 0);
        check("le_advertising_enabled 0 after Clear", x->bt.le_advertising_enabled, 0);

        printf("scenario: HCI Reset clears the adv set model\n");
        uint8_t p36c_cmd[28];
        memcpy(p36c_cmd, p36_cmd, sizeof p36c_cmd);
        p36c_cmd[3] = 0x02; /* handle 2 */
        drive("LE Set Extended Advertising Parameters (h2)", p36c_cmd, 28, 0x2036, 7);
        drive("HCI Reset", reset_cmd, 3, 0x0c03, 6);
        check("no adv sets remain after HCI Reset", adv_count(), 0);

        printf("scenario: capacity: 8 sets live, the 9th is refused 0x07, then Clear\n");
        for (int h = 0; h < 8; h++) {
            uint8_t cap_cmd[28];
            memcpy(cap_cmd, p36_cmd, sizeof cap_cmd);
            cap_cmd[3] = (uint8_t)h;
            char nm[64];
            snprintf(nm, sizeof nm, "LE Set Extended Advertising Parameters (capacity h%d)", h);
            drive(nm, cap_cmd, 28, 0x2036, 7);
        }
        uint8_t cap9_cmd[28];
        memcpy(cap9_cmd, p36_cmd, sizeof cap9_cmd);
        cap9_cmd[3] = 0x09;
        drive_st("LE Set Extended Advertising Parameters (9th set)", cap9_cmd, 28, 0x2036, 0x07);
        drive("LE Clear Advertising Sets (final)", clear_cmd, 3, 0x203d, 6);
        check("no adv sets remain after final Clear", adv_count(), 0);
    }

    printf("test_bt_hci_postinit: %d checks, %d failures\n", checks, failures);
    printf("%s\n", failures == 0 ? "POSTINIT SCENARIO PASS" : "POSTINIT SCENARIO FAIL");
    return failures != 0;
}
