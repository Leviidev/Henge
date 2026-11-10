/* Standalone test of the HCI core: drives the exact command packets a
   host stack sends at bring-up and checks the Command Complete events.
   The original CSR suite runs unchanged under
   HV_BT_PERSONALITY=csr (byte-identical CSR behavior), then a BCM20702
   suite runs under HV_BT_PERSONALITY=bcm20702 covering the Broadcom identity,
   the BD_ADDR OUI, and a scripted patchram vendor sequence. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bt_hci.h"

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

static uint32_t cmd(HvBtHci *bt, uint16_t opcode, const uint8_t *par, uint8_t plen, uint8_t *ev) {
    uint8_t pkt[300];
    pkt[0] = (uint8_t)opcode;
    pkt[1] = (uint8_t)(opcode >> 8);
    pkt[2] = plen;
    if (plen) memcpy(pkt + 3, par, plen);
    hv_bt_command(bt, pkt, (uint32_t)(3 + plen));
    return hv_bt_take_event(bt, ev, 256);
}

static void csr_suite(void) {
    setenv("HV_BT_PERSONALITY", "csr", 1);
    check("csr usb vid", hv_bt_usb_vid(), 0x0a12);
    check("csr usb pid", hv_bt_usb_pid(), 0x0001);
    check_str("csr usb manufacturer", hv_bt_usb_manufacturer(), "HengeVM");
    check_str("csr usb product", hv_bt_usb_product(), "HengeVM Bluetooth");

    HvBtHci bt;
    hv_bt_init(&bt);
    uint8_t ev[256];
    uint32_t n;

    n = cmd(&bt, 0x0c03, NULL, 0, ev); /* Reset */
    check("reset event code", ev[0], 0x0e);
    check("reset plen byte is 4 + 0", ev[1], 4);
    check("reset status", ev[5], 0);
    check("reset event len", (long)n, 6);

    n = cmd(&bt, 0x1001, NULL, 0, ev); /* Read Local Version */
    check("version opcode echo", ev[3] | ev[4] << 8, 0x1001);
    check("version status", ev[5], 0);
    check("hci version nonzero", ev[6] != 0, 1);
    check("manufacturer CSR 0x000a", ev[10] | ev[11] << 8, 0x000a);
    (void)n;

    n = cmd(&bt, 0x1009, NULL, 0, ev); /* Read BD_ADDR (spec opcode) */
    check("bdaddr status", ev[5], 0);
    check("bdaddr plen byte is 4 + 6", ev[1], 10);
    check("bdaddr msb 00:1A:7D", ev[11], 0x00);
    check("bdaddr len", (long)n, 12);

    n = cmd(&bt, 0x1002, NULL, 0, ev); /* Read Local Supported Commands (spec) */
    check("supported cmds status", ev[5], 0);
    check("supported cmds plen byte is 4 + 64", ev[1], 68);
    check("supported cmds len", (long)n, 70);
    check("supported cmds octet 0 (Inquiry, Inquiry Cancel (claim), Disconnect)", ev[6], 0x23);
    check("supported cmds octet 5 (Set Event Mask, Reset)", ev[11], 0xc0);
    check("supported cmds octet 14 (Version, Commands, Features, ExtFeatures, BufferSize)", ev[20], 0xf8); /* +0x1004 (implemented) +0x1005 (real case) */
    check("supported cmds octet 15 (Buffer Size, BD_ADDR)", ev[21], 0x03);
    check("supported cmds octet 22 (Set Event Mask Page 2)", ev[28], 0x04);
    check("supported cmds octet 25 (LE init cmds)", ev[31], 0xb7);
    check("supported cmds octet 26 (LE scan/connect cmds)", ev[32], 0x7f); /* +0x200F (implemented) */
    check("supported cmds octet 28 (LE Read Supported States)", ev[34], 0x08);
    check("supported cmds octet 1 is zero (nothing unhonoured claimed)", ev[7], 0);

    n = cmd(&bt, 0x1003, NULL, 0, ev); /* Read Local Supported Features (spec) */
    check("features status", ev[5], 0);
    check("features plen byte is 4 + 8", ev[1], 12);
    check("features len", (long)n, 14);
    check("features byte 4 has LE Supported (Controller) set", ev[10] & 0x40, 0x40);

    n = cmd(&bt, 0x2002, NULL, 0, ev); /* LE Read Buffer Size (spec) */
    check("le bufsize status", ev[5], 0);
    check("le bufsize plen byte is 4 + 3", ev[1], 7);
    check("le bufsize len", (long)n, 9);
    check("le acl len 251", ev[6], 251);

    n = cmd(&bt, 0x2003, NULL, 0, ev); /* LE Read Local Supported Features (spec) */
    check("le features status", ev[5], 0);
    check("le features len", (long)n, 14);
    check("le features byte 0 (encryption + conn param req)", ev[6], 0x03);

    n = cmd(&bt, 0x201c, NULL, 0, ev); /* LE Read Supported States (spec) */
    check("le states status", ev[5], 0);
    check("le states len", (long)n, 14);
    check("le states byte 0", ev[6], 0xff);

    n = cmd(&bt, 0x2005, (const uint8_t *)"\x11\x22\x33\x44\x55\x66", 6, ev); /* LE Set Random Address (spec) */
    check("le set random addr status", ev[5], 0);
    check("le set random addr is status-only (len 6)", (long)n, 6);
    check("le set random addr plen byte is 4", ev[1], 4);
    check("le random addr stored", memcmp(bt.le_random_addr, "\x11\x22\x33\x44\x55\x66", 6), 0);

    n = cmd(&bt, 0x0401, (const uint8_t *)"\x33\x8b\x9e\x08\x00", 5, ev); /* Inquiry */
    check("inquiry first event is cmd status", ev[0], 0x0f);
    n = hv_bt_take_event(&bt, ev, sizeof ev);
    check("inquiry complete follows", ev[0], 0x01);
    check("inquiry complete status", ev[2], 0);

    /* ACL loopback: guest -> core -> guest */
    bt.loopback = 1;
    static const uint8_t acl[8] = {0x01, 0x20, 0x04, 0x00, 0xde, 0xad, 0xbe, 0xef};
    hv_bt_acl_from_guest(&bt, acl, sizeof acl);
    check("acl pending after loopback", hv_bt_acl_pending(&bt), 1);
    n = hv_bt_take_acl(&bt, ev, sizeof ev);
    check("acl echo len", (long)n, 8);
    check("acl echo payload", memcmp(ev, acl, 8), 0);
    printf("csr suite done: %d checks so far, %d failures\n", checks, failures);
}

static void bcm_suite(void) {
    setenv("HV_BT_PERSONALITY", "bcm20702", 1);
    check_str("personality name", hv_bt_personality_name(), "bcm20702");
    check("bcm usb vid", hv_bt_usb_vid(), 0x0a5c);
    check("bcm usb pid", hv_bt_usb_pid(), 0x21e8);
    check_str("bcm usb manufacturer", hv_bt_usb_manufacturer(), "Broadcom Corp");
    check_str("bcm usb product", hv_bt_usb_product(), "BCM20702A0");
    check_str("bcm usb serial", hv_bt_usb_serial(), "001FE1B20702");
    check_str("bcm local name helper", hv_bt_local_name(), "BCM20702A0");

    HvBtHci bt;
    hv_bt_init(&bt);
    uint8_t ev[256];
    uint32_t n;

    n = cmd(&bt, 0x0c03, NULL, 0, ev); /* Reset */
    check("bcm reset event code", ev[0], 0x0e);
    check("bcm reset plen byte is 4 + 0", ev[1], 4);
    check("bcm reset status", ev[5], 0);
    check("bcm reset event len", (long)n, 6);

    n = cmd(&bt, 0x1001, NULL, 0, ev); /* Read Local Version */
    check("bcm version opcode echo", ev[3] | ev[4] << 8, 0x1001);
    check("bcm version plen byte is 4 + 8", ev[1], 12);
    check("bcm version status", ev[5], 0);
    check("bcm hci version 6 (BT 4.0)", ev[6], 6);
    check("bcm lmp version 6 (BT 4.0)", ev[9], 6);
    check("bcm manufacturer Broadcom 0x000f", ev[10] | ev[11] << 8, 0x000f);

    n = cmd(&bt, 0x1009, NULL, 0, ev); /* Read BD_ADDR (spec): display 00:1F:E1:B2:07:02 */
    check("bcm bdaddr status", ev[5], 0);
    check("bcm bdaddr plen byte is 4 + 6", ev[1], 10);
    check("bcm bdaddr len", (long)n, 12);
    check("bcm bdaddr wire[0] 02", ev[6], 0x02);
    check("bcm bdaddr wire[1] 07", ev[7], 0x07);
    check("bcm bdaddr wire[2] b2", ev[8], 0xb2);
    check("bcm bdaddr OUI byte E1", ev[9], 0xe1);
    check("bcm bdaddr OUI byte 1F", ev[10], 0x1f);
    check("bcm bdaddr OUI byte 00", ev[11], 0x00);

    n = cmd(&bt, 0x0c14, NULL, 0, ev); /* Read Local Name */
    check("bcm local name status", ev[5], 0);
    check("bcm local name plen byte is 4 + 248", ev[1], 252);
    check("bcm local name len", (long)n, 254);
    check("bcm local name payload", memcmp(ev + 6, "BCM20702A0", 10), 0);

    n = cmd(&bt, 0x1002, NULL, 0, ev); /* Read Local Supported Commands (spec) */
    check("bcm supported cmds status", ev[5], 0);
    check("bcm supported cmds plen byte is 4 + 64", ev[1], 68);
    check("bcm supported cmds len", (long)n, 70);
    check("bcm supported cmds octet 25 (LE init cmds)", ev[31], 0xb7);
    check("bcm supported cmds octet 26 (LE scan/connect cmds)", ev[32], 0x7f); /* +0x200F (implemented) */
    check("bcm supported cmds octet 28 (LE Read Supported States)", ev[34], 0x08);

    n = cmd(&bt, 0x1003, NULL, 0, ev); /* Read Local Supported Features (spec) */
    check("bcm features status", ev[5], 0);
    check("bcm features plen byte is 4 + 8", ev[1], 12);
    check("bcm features len", (long)n, 14);
    check("bcm features byte 4 has LE Supported (Controller) set", ev[10] & 0x40, 0x40);

    n = cmd(&bt, 0x2002, NULL, 0, ev); /* LE Read Buffer Size (spec) */
    check("bcm le bufsize status", ev[5], 0);
    check("bcm le bufsize plen byte is 4 + 3", ev[1], 7);
    check("bcm le acl len 251", ev[6], 251);

    n = cmd(&bt, 0x2003, NULL, 0, ev); /* LE Read Local Supported Features (spec) */
    check("bcm le features status", ev[5], 0);
    check("bcm le features len", (long)n, 14);
    check("bcm le features byte 0", ev[6], 0x03);

    n = cmd(&bt, 0x201c, NULL, 0, ev); /* LE Read Supported States (spec) */
    check("bcm le states status", ev[5], 0);
    check("bcm le states len", (long)n, 14);

    n = cmd(&bt, 0x2005, (const uint8_t *)"\xaa\xbb\xcc\xdd\xee\xff", 6, ev); /* LE Set Random Address (spec) */
    check("bcm le set random addr status", ev[5], 0);
    check("bcm le set random addr is status-only (len 6)", (long)n, 6);
    check("bcm le random addr stored", memcmp(bt.le_random_addr, "\xaa\xbb\xcc\xdd\xee\xff", 6), 0);

    /* Scripted Broadcom patchram sequence, as the USB transport issues it:
       Download Minidriver, Write RAM chunks, an unrelated vendor command,
       an unknown vendor opcode, Launch RAM, then HCI Reset. Every step
       must complete successfully against the RAM stub. */
    n = cmd(&bt, 0xfc2e, NULL, 0, ev); /* Download Minidriver */
    check("patchram dl event code", ev[0], 0x0e);
    check("patchram dl opcode echo", ev[3] | ev[4] << 8, 0xfc2e);
    check("patchram dl status", ev[5], 0);
    check("patchram dl event len", (long)n, 6);
    check("patchram active after dl", bt.patchram_active, 1);

    uint8_t chunk[40];
    memset(chunk, 0xa5, sizeof chunk); /* bytes 0-3 are the RAM address */
    n = cmd(&bt, 0xfc4c, chunk, 20, ev); /* Write RAM: 4 addr + 16 data */
    check("patchram write1 opcode echo", ev[3] | ev[4] << 8, 0xfc4c);
    check("patchram write1 status", ev[5], 0);
    check("patchram bytes after write1", (long)bt.patchram_bytes, 16);
    n = cmd(&bt, 0xfc4c, chunk, 36, ev); /* Write RAM: 4 addr + 32 data */
    check("patchram write2 status", ev[5], 0);
    check("patchram bytes after write2", (long)bt.patchram_bytes, 48);

    n = cmd(&bt, 0xfc01, (const uint8_t *)"\x11\x22\x33\x44\x55\x66", 6, ev); /* vendor Write BD_ADDR */
    check("vendor fc01 status", ev[5], 0);
    check("vendor fc01 applied to core bd_addr", memcmp(bt.bd_addr, "\x11\x22\x33\x44\x55\x66", 6), 0);
    n = cmd(&bt, 0x1009, NULL, 0, ev); /* Read BD_ADDR now returns the FC01 address */
    check("bdaddr after fc01 status", ev[5], 0);
    check("bdaddr after fc01 wire bytes", memcmp(ev + 6, "\x11\x22\x33\x44\x55\x66", 6), 0);
    n = cmd(&bt, 0xfc99, (const uint8_t *)"\x01\x02", 2, ev); /* unknown vendor opcode */
    check("vendor unknown event code", ev[0], 0x0e);
    check("vendor unknown opcode echo", ev[3] | ev[4] << 8, 0xfc99);
    check("vendor unknown status", ev[5], 0);
    check("vendor cmds seen", (long)bt.vendor_cmds_seen, 5);

    n = cmd(&bt, 0xfc4e, (const uint8_t *)"\xff\xff\xff\xff", 4, ev); /* Launch RAM */
    check("patchram launch status", ev[5], 0);
    check("patchram launched", bt.patchram_launched, 1);
    check("patchram inactive after launch", bt.patchram_active, 0);

    n = cmd(&bt, 0x0c03, NULL, 0, ev); /* HCI Reset after launch */
    check("bcm post-patchram reset status", ev[5], 0);
    check("patchram survives reset", bt.patchram_launched, 1);
    n = cmd(&bt, 0x1001, NULL, 0, ev); /* version still Broadcom after reset */
    check("bcm manufacturer after patchram reset", ev[10] | ev[11] << 8, 0x000f);

    n = cmd(&bt, 0x0401, (const uint8_t *)"\x33\x8b\x9e\x08\x00", 5, ev); /* Inquiry still correct */
    check("bcm inquiry first event is cmd status", ev[0], 0x0f);
    n = hv_bt_take_event(&bt, ev, sizeof ev);
    check("bcm inquiry complete follows", ev[0], 0x01);
    check("bcm inquiry complete status", ev[2], 0);
    printf("bcm suite done: %d checks total, %d failures\n", checks, failures);
}

int main(void) {
    csr_suite();
    bcm_suite();
    /* Default personality (no env influence left by suites is fine: the
       suites set it explicitly; verify the documented default by clearing) */
    unsetenv("HV_BT_PERSONALITY");
    check_str("default personality is bcm20702", hv_bt_personality_name(), "bcm20702");
    printf("test_bt: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
