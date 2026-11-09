/* Per-machine BD_ADDR derivation: the seeded path of hv_bt_init.
   A machine UUID seed (hv_bt_set_machine_uuid) makes the core compose
   its controller address as the personality's high three octets plus a
   suffix derived from the seed (FNV-1a 64 over the seed's 16 bytes, low
   24 bits, with the zero and fixed-suffix guards), and makes the BCM
   USB serial string the derived address's display hex at both sites
   that serve it (hv_bt_usb_serial and the xHCI string table, reached
   here through the shipped transport's own bt_string). With no seed, or
   an all-zero seed, the fixed per-personality addresses and serial are
   served byte-for-byte. Expected addresses below are fixed vectors;
   the guard cases carry UUIDs whose unguarded suffix is asserted in
   the test itself (fnv_ref) so the guard coverage is proven, not
   assumed. Build like the other xhci.c-including suites: this file
   supplies xhci.c, so the link omits build/xhci.o. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xhci.c" /* the shipped transport, statics and all */

static int checks, failures;
static void check(const char *what, long got, long want) {
    checks++;
    if (got != want) {
        printf("  FAIL %s: %ld, expected %ld\n", what, got, want);
        failures++;
    }
}
static void check_str(const char *what, const char *got, const char *want) {
    checks++;
    if (strcmp(got, want) != 0) {
        printf("  FAIL %s: \"%s\", expected \"%s\"\n", what, got, want);
        failures++;
    }
}
static void check_addr(const char *what, const uint8_t got[6], const uint8_t want[6]) {
    checks++;
    if (memcmp(got, want, 6) != 0) {
        printf("  FAIL %s: %02x:%02x:%02x:%02x:%02x:%02x, expected %02x:%02x:%02x:%02x:%02x:%02x\n", what,
               got[5], got[4], got[3], got[2], got[1], got[0],
               want[5], want[4], want[3], want[2], want[1], want[0]);
        failures++;
    }
}

static uint32_t cmd(HvBtHci *bt, uint16_t opcode, const uint8_t *par, uint8_t plen, uint8_t *ev) {
    uint8_t pkt[300];
    pkt[0] = (uint8_t)opcode;
    pkt[1] = (uint8_t)(opcode >> 8);
    pkt[2] = plen;
    if (plen) memcpy(pkt + 3, par, plen);
    hv_bt_command(bt, pkt, (uint32_t)(3 + plen));
    return hv_bt_take_event(bt, ev, 256);
}

/* Read BD_ADDR (0x1009) over the command path and compare the served
   bytes (wire order) with want. */
static void check_served(const char *what, HvBtHci *bt, const uint8_t want[6]) {
    uint8_t ev[256];
    uint32_t n = cmd(bt, 0x1009, NULL, 0, ev);
    check(what, (long)n, 12);
    char lbl[128];
    snprintf(lbl, sizeof lbl, "%s (served bytes)", what);
    check_addr(lbl, ev + 6, want);
}

/* Reference FNV-1a 64, written for this test: the unguarded suffix a
   guard-case UUID hashes to, so the test proves the guard fired. */
static uint32_t fnv_ref_suffix(const uint8_t uuid[16]) {
    uint64_t h = 14695981039346656037ULL;
    for (int i = 0; i < 16; i++) {
        h ^= uuid[i];
        h *= 1099511628211ULL;
    }
    return (uint32_t)(h & 0xffffff);
}

static const uint8_t legacy_bcm[6] = {0x02, 0x07, 0xb2, 0xe1, 0x1f, 0x00}; /* 00:1F:E1:B2:07:02 */
static const uint8_t legacy_csr[6] = {0x13, 0x71, 0xda, 0x7d, 0x1a, 0x00}; /* 00:1A:7D:DA:71:13 */

static const uint8_t uuid_a[16] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                   0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
static const uint8_t uuid_b[16] = {0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
                                   0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00};
static const uint8_t uuid_c[16] = {0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
                                   0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00};
/* Crafted so the unguarded suffix is 00:00:00 / B2:07:02 / DA:71:13. */
static const uint8_t uuid_guard_zero[16] = {0x46, 0x4e, 0x56, 0x2d, 0x47, 0x55, 0x41, 0x52,
                                            0x44, 0x2d, 0x30, 0x31, 0xe0, 0xfa, 0x0d, 0x00};
static const uint8_t uuid_guard_bcm[16] = {0x46, 0x4e, 0x56, 0x2d, 0x47, 0x55, 0x41, 0x52,
                                           0x44, 0x2d, 0x30, 0x31, 0x6f, 0xa9, 0x0e, 0x01};
static const uint8_t uuid_guard_csr[16] = {0x46, 0x4e, 0x56, 0x2d, 0x47, 0x55, 0x41, 0x52,
                                           0x44, 0x2d, 0x30, 0x31, 0x93, 0x41, 0x07, 0x01};

int main(void) {
    HvBtHci bt;

    /* ---- no seed: the fixed addresses, byte-for-byte ---- */
    hv_bt_set_machine_uuid(NULL);
    setenv("HV_BT_PERSONALITY", "bcm20702", 1);
    hv_bt_init(&bt);
    check_addr("seedless bcm bd_addr", bt.bd_addr, legacy_bcm);
    check_served("seedless bcm read bd_addr", &bt, legacy_bcm);
    check_str("seedless bcm serial (core)", hv_bt_usb_serial(), "001FE1B20702");
    check_str("seedless bcm serial (xhci table)", bt_string(3), "001FE1B20702");
    check_str("seedless bcm manufacturer (xhci table)", bt_string(1), "Broadcom Corp");

    setenv("HV_BT_PERSONALITY", "csr", 1);
    hv_bt_init(&bt);
    check_addr("seedless csr bd_addr", bt.bd_addr, legacy_csr);
    check_served("seedless csr read bd_addr", &bt, legacy_csr);
    check_str("seedless csr serial (core)", hv_bt_usb_serial(), "1");
    check_str("seedless csr serial (xhci table)", bt_string(3), "1");

    /* An all-zero UUID is no seed: the fixed addresses again. */
    static const uint8_t zero_uuid[16] = {0};
    hv_bt_set_machine_uuid(zero_uuid);
    setenv("HV_BT_PERSONALITY", "bcm20702", 1);
    hv_bt_init(&bt);
    check_addr("zero-uuid bcm bd_addr", bt.bd_addr, legacy_bcm);
    check_str("zero-uuid bcm serial (core)", hv_bt_usb_serial(), "001FE1B20702");

    /* ---- seeded: distinct UUIDs, distinct addresses; stable per UUID ---- */
    static const uint8_t a_bcm[6] = {0xf5, 0x3e, 0x1b, 0xe1, 0x1f, 0x00}; /* 00:1F:E1:1B:3E:F5 */
    hv_bt_set_machine_uuid(uuid_a);
    hv_bt_init(&bt);
    check_addr("uuid-a bcm bd_addr", bt.bd_addr, a_bcm);
    check_served("uuid-a bcm read bd_addr", &bt, a_bcm);
    check_str("uuid-a bcm serial (core)", hv_bt_usb_serial(), "001FE11B3EF5");
    check_str("uuid-a bcm serial (xhci table)", bt_string(3), "001FE11B3EF5");
    check_str("uuid-a bcm manufacturer (xhci table)", bt_string(1), "Broadcom Corp");
    uint8_t a_first[6];
    memcpy(a_first, bt.bd_addr, 6);
    hv_bt_init(&bt); /* same seed: the same address, every init */
    check_addr("uuid-a bcm bd_addr stable across init", bt.bd_addr, a_first);

    static const uint8_t b_bcm[6] = {0xa5, 0x00, 0x52, 0xe1, 0x1f, 0x00}; /* 00:1F:E1:52:00:A5 */
    hv_bt_set_machine_uuid(uuid_b);
    hv_bt_init(&bt);
    check_addr("uuid-b bcm bd_addr", bt.bd_addr, b_bcm);
    check("uuid-b differs from uuid-a", memcmp(bt.bd_addr, a_first, 6) != 0, 1);
    check_str("uuid-b bcm serial (core)", hv_bt_usb_serial(), "001FE15200A5");
    check_str("uuid-b bcm serial (xhci table)", bt_string(3), "001FE15200A5");

    static const uint8_t c_bcm[6] = {0xb2, 0xb1, 0x2a, 0xe1, 0x1f, 0x00}; /* 00:1F:E1:2A:B1:B2 */
    hv_bt_set_machine_uuid(uuid_c);
    hv_bt_init(&bt);
    check_addr("uuid-c bcm bd_addr", bt.bd_addr, c_bcm);
    check("uuid-c differs from uuid-a", memcmp(bt.bd_addr, a_first, 6) != 0, 1);
    check_str("uuid-c bcm serial (core)", hv_bt_usb_serial(), "001FE12AB1B2");

    /* ---- seeded CSR: same suffix, locally administered high octets ---- */
    static const uint8_t a_csr[6] = {0xf5, 0x3e, 0x1b, 0x7d, 0x1a, 0x02}; /* 02:1A:7D:1B:3E:F5 */
    hv_bt_set_machine_uuid(uuid_a);
    setenv("HV_BT_PERSONALITY", "csr", 1);
    hv_bt_init(&bt);
    check_addr("uuid-a csr bd_addr", bt.bd_addr, a_csr);
    check_served("uuid-a csr read bd_addr", &bt, a_csr);
    check("uuid-a csr suffix equals bcm suffix", memcmp(bt.bd_addr, a_first, 3), 0);
    check_str("uuid-a csr serial (core)", hv_bt_usb_serial(), "1");
    check_str("uuid-a csr serial (xhci table)", bt_string(3), "1");

    /* ---- guards: a derived suffix of 00:00:00 or of either fixed
       suffix is XORed with 0x000001 ---- */
    setenv("HV_BT_PERSONALITY", "bcm20702", 1);
    check("guard-zero uuid hashes to suffix 0", (long)fnv_ref_suffix(uuid_guard_zero), 0);
    static const uint8_t gz_bcm[6] = {0x01, 0x00, 0x00, 0xe1, 0x1f, 0x00}; /* 00:1F:E1:00:00:01 */
    hv_bt_set_machine_uuid(uuid_guard_zero);
    hv_bt_init(&bt);
    check_addr("guard-zero bcm bd_addr", bt.bd_addr, gz_bcm);
    check_str("guard-zero bcm serial (core)", hv_bt_usb_serial(), "001FE1000001");
    check_str("guard-zero bcm serial (xhci table)", bt_string(3), "001FE1000001");

    static const uint8_t gz_csr[6] = {0x01, 0x00, 0x00, 0x7d, 0x1a, 0x02}; /* 02:1A:7D:00:00:01 */
    setenv("HV_BT_PERSONALITY", "csr", 1);
    hv_bt_init(&bt); /* seed still guard-zero */
    check_addr("guard-zero csr bd_addr", bt.bd_addr, gz_csr);
    setenv("HV_BT_PERSONALITY", "bcm20702", 1);

    check("guard-bcm uuid hashes to the bcm fixed suffix", (long)fnv_ref_suffix(uuid_guard_bcm), 0xb20702);
    static const uint8_t gb_bcm[6] = {0x03, 0x07, 0xb2, 0xe1, 0x1f, 0x00}; /* 00:1F:E1:B2:07:03 */
    hv_bt_set_machine_uuid(uuid_guard_bcm);
    hv_bt_init(&bt);
    check_addr("guard-bcm bcm bd_addr", bt.bd_addr, gb_bcm);
    check_str("guard-bcm bcm serial (core)", hv_bt_usb_serial(), "001FE1B20703");
    check_str("guard-bcm bcm serial (xhci table)", bt_string(3), "001FE1B20703");

    check("guard-csr uuid hashes to the csr fixed suffix", (long)fnv_ref_suffix(uuid_guard_csr), 0xda7113);
    static const uint8_t gc_bcm[6] = {0x12, 0x71, 0xda, 0xe1, 0x1f, 0x00}; /* 00:1F:E1:DA:71:12 */
    hv_bt_set_machine_uuid(uuid_guard_csr);
    hv_bt_init(&bt);
    check_addr("guard-csr bcm bd_addr", bt.bd_addr, gc_bcm);
    check_str("guard-csr bcm serial (core)", hv_bt_usb_serial(), "001FE1DA7112");
    check_str("guard-csr bcm serial (xhci table)", bt_string(3), "001FE1DA7112");

    /* ---- the guest's vendor Write BD_ADDR still overrides, seeded ---- */
    hv_bt_set_machine_uuid(uuid_a);
    hv_bt_init(&bt);
    uint8_t ev[256];
    cmd(&bt, 0xfc01, (const uint8_t *)"\x11\x22\x33\x44\x55\x66", 6, ev);
    static const uint8_t fc01_addr[6] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66};
    check_served("seeded fc01 override read bd_addr", &bt, fc01_addr);

    /* ---- clearing the seed restores the fixed identity exactly ---- */
    hv_bt_set_machine_uuid(NULL);
    hv_bt_init(&bt);
    check_addr("cleared-seed bcm bd_addr", bt.bd_addr, legacy_bcm);
    check_str("cleared-seed bcm serial (core)", hv_bt_usb_serial(), "001FE1B20702");
    check_str("cleared-seed bcm serial (xhci table)", bt_string(3), "001FE1B20702");

    printf("test_bt_bdaddr: %d checks, %d failures\n", checks, failures);
    if (failures == 0) printf("test_bt_bdaddr: PASS\n");
    return failures ? 1 : 0;
}
