/* Standalone BLE bridge harness: a MOCK CoreBluetooth-side
   backend sits behind the HCI core's real seam (hv_bt_set_acl_sink /
   hv_bt_inject_acl / hv_bt_backend_inject_adv_report) and a scripted guest
   scenario runs against the core exactly as a bound macOS stack would drive
   it: scan, discover two fake peripherals, connect, exchange a GATT-style
   ACL payload both ways, disconnect. Every step is an assertion and every
   assertion is logged. This is the design-level rehearsal for the on-device
   CoreBluetooth bridge specified in radio-r1.md section 6. */
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
    } else {
        printf("  ok   %s\n", what);
    }
}

/* ---- mock CoreBluetooth backend ---------------------------------------- */

typedef struct MockPeripheral {
    uint8_t addr[6]; /* HCI wire order (LSB first) */
    uint8_t addr_type;
    int8_t rssi;
    uint8_t adv[31];
    uint32_t adv_len;
} MockPeripheral;

/* P1: a HID-over-GATT keyboard (service 0x1812), the first profile. */
static const MockPeripheral kP1 = {
    {0x78, 0x56, 0x34, 0x12, 0x9a, 0xc3}, 0, -42,
    {0x02, 0x01, 0x06,             /* Flags: LE general discoverable, no BR/EDR */
     0x03, 0x03, 0x12, 0x18,       /* complete 16-bit UUIDs: 0x1812 HID */
     0x08, 0x09, 'H', 'e', 'n', 'g', 'e', 'K', 'B'}, /* complete local name */
    16};
/* P2: a heart-rate sensor (service 0x180d), random address. */
static const MockPeripheral kP2 = {
    {0x21, 0x43, 0x65, 0x87, 0xa9, 0xcb}, 1, -67,
    {0x02, 0x01, 0x06,
     0x03, 0x03, 0x0d, 0x18,
     0x0c, 0x09, 'H', 'e', 'n', 'g', 'e', 'S', 'e', 'n', 's', 'o', 'r'},
    20};

typedef struct MockBackend {
    HvBtHci *bt;
    int acl_received;
    uint8_t last_acl[HV_BT_MAX_PACKET];
    uint32_t last_acl_len;
} MockBackend;

/* The mock's didReceiveData: answer an ATT Read Request (0x0a) with a Read
   Response (0x0b) carrying "OK", on the same connection handle, exactly as
   a GATT read completion would be translated back by the real bridge. */
static void mock_acl_sink(void *ctx, const uint8_t *pkt, uint32_t len) {
    MockBackend *mock = ctx;
    mock->acl_received++;
    mock->last_acl_len = len;
    memcpy(mock->last_acl, pkt, len);
    if (len < 9) return;
    uint16_t handle = (uint16_t)(pkt[0] | (pkt[1] & 0x0f) << 8);
    const uint8_t *att = pkt + 8; /* skip ACL header (4) + L2CAP header (4) */
    if (att[0] != 0x0a) return;
    uint8_t resp[11];
    resp[0] = (uint8_t)handle;
    resp[1] = (uint8_t)(0x20 | (handle >> 8)); /* PB = first, non-flushable */
    resp[2] = 7;                              /* ACL payload length */
    resp[3] = 0;
    resp[4] = 3; /* L2CAP length */
    resp[5] = 0;
    resp[6] = 0x04; /* L2CAP CID: ATT */
    resp[7] = 0;
    resp[8] = 0x0b; /* ATT Read Response */
    resp[9] = 'O';
    resp[10] = 'K';
    hv_bt_inject_acl(mock->bt, resp, sizeof resp);
}

/* The mock's didDiscoverPeripheral: forward one discovery to the core. */
static int mock_discover(MockBackend *mock, const MockPeripheral *p) {
    (void)mock;
    return hv_bt_backend_inject_adv_report(mock->bt, p->addr_type, p->addr, p->rssi, p->adv, p->adv_len);
}

/* ---- guest-side helpers -------------------------------------------------- */

static uint32_t cmd(HvBtHci *bt, uint16_t opcode, const uint8_t *par, uint8_t plen, uint8_t *ev) {
    uint8_t pkt[300];
    pkt[0] = (uint8_t)opcode;
    pkt[1] = (uint8_t)(opcode >> 8);
    pkt[2] = plen;
    if (plen) memcpy(pkt + 3, par, plen);
    hv_bt_command(bt, pkt, (uint32_t)(3 + plen));
    return hv_bt_take_event(bt, ev, 256);
}

int main(void) {
    unsetenv("HV_BT_PERSONALITY"); /* exercise the documented default */
    HvBtHci bt;
    hv_bt_init(&bt);
    MockBackend mock;
    memset(&mock, 0, sizeof mock);
    mock.bt = &bt;
    hv_bt_set_acl_sink(&bt, mock_acl_sink, &mock);
    uint8_t ev[256];
    uint32_t n;

    printf("scenario: reset and bring-up\n");
    n = cmd(&bt, 0x0c03, NULL, 0, ev);
    check("reset completes", ev[0], 0x0e);
    check("reset status ok", ev[5], 0);
    n = cmd(&bt, 0x2002, NULL, 0, ev); /* LE Read Buffer Size (spec opcode) */
    check("le buffer size ok", ev[5], 0);
    check("le buffer size plen byte is 4 + 3", ev[1], 7);
    check("le buffer size event len", (long)n, 9);
    check("le buffer 251", ev[6], 251);

    printf("scenario: LE scan synthesizes advertising reports\n");
    static const uint8_t scanpar[7] = {0x01, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00};
    n = cmd(&bt, 0x200b, scanpar, 7, ev); /* LE Set Scan Parameters */
    check("set scan params completes", ev[0], 0x0e);
    check("set scan params status ok", ev[5], 0);
    static const uint8_t scanon[2] = {0x01, 0x00};
    n = cmd(&bt, 0x200c, scanon, 2, ev); /* LE Set Scan Enable */
    check("set scan enable completes", ev[0], 0x0e);
    check("set scan enable status ok", ev[5], 0);
    check("core scan state on", bt.le_scan_enabled, 1);

    check("mock discovery P1 accepted", mock_discover(&mock, &kP1), 1);
    check("mock discovery P2 accepted", mock_discover(&mock, &kP2), 1);

    n = hv_bt_take_event(&bt, ev, sizeof ev);
    check("adv report 1 is LE meta", ev[0], 0x3e);
    check("adv report 1 subevent", ev[2], 0x02);
    check("adv report 1 num reports", ev[3], 1);
    check("adv report 1 type ADV_IND", ev[4], 0x00);
    check("adv report 1 addr type", ev[5], kP1.addr_type);
    check("adv report 1 addr matches", memcmp(ev + 6, kP1.addr, 6), 0);
    check("adv report 1 data len", ev[12], (long)kP1.adv_len);
    check("adv report 1 carries HID uuid 0x1812", ev[18] == 0x12 && ev[19] == 0x18, 1);
    check("adv report 1 rssi", (int8_t)ev[13 + kP1.adv_len], kP1.rssi);
    n = hv_bt_take_event(&bt, ev, sizeof ev);
    check("adv report 2 is LE meta", ev[0], 0x3e);
    check("adv report 2 num reports", ev[3], 1);
    check("adv report 2 addr matches", memcmp(ev + 6, kP2.addr, 6), 0);
    check("adv report 2 rssi", (int8_t)ev[13 + kP2.adv_len], kP2.rssi);
    check("no third adv report", hv_bt_event_pending(&bt), 0);

    static const uint8_t scanoff[2] = {0x00, 0x00};
    n = cmd(&bt, 0x200c, scanoff, 2, ev);
    check("scan disable status ok", ev[5], 0);
    check("discovery while not scanning is dropped", mock_discover(&mock, &kP1), 0);
    check("no event from dropped discovery", hv_bt_event_pending(&bt), 0);

    printf("scenario: LE create connection\n");
    uint8_t connpar[25];
    memset(connpar, 0, sizeof connpar);
    connpar[0] = 0x10; connpar[2] = 0x10;      /* scan interval/window */
    connpar[5] = kP1.addr_type;                /* peer address type */
    memcpy(connpar + 6, kP1.addr, 6);          /* peer address */
    connpar[13] = 0x18;                        /* interval min 0x0018 */
    connpar[15] = 0x28;                        /* interval max 0x0028 */
    connpar[19] = 0xf4; connpar[20] = 0x01;    /* supervision timeout 0x01f4 */
    n = cmd(&bt, 0x200d, connpar, 25, ev);     /* LE Create Connection */
    check("create connection first event is cmd status", ev[0], 0x0f);
    check("create connection status ok", ev[2], 0);
    n = hv_bt_take_event(&bt, ev, sizeof ev);
    check("connection complete is LE meta", ev[0], 0x3e);
    check("connection complete subevent", ev[2], 0x01);
    check("connection complete status ok", ev[3], 0);
    check("connection handle allocated 0x0040", ev[4] | ev[5] << 8, 0x0040);
    check("connection role central", ev[6], 0);
    check("connection peer addr matches", memcmp(ev + 8, kP1.addr, 6), 0);
    check("connection interval is max requested", ev[14] | ev[15] << 8, 0x0028);
    check("core tracks live handle", bt.le_conn_handle, 0x0040);

    printf("scenario: ACL/GATT payload round trip guest->mock->guest\n");
    /* ACL: handle 0x0040 PB=2, L2CAP len 3 CID ATT(0x0004), ATT Read Req h 0x0003 */
    static const uint8_t acl_out[11] = {0x40, 0x20, 0x07, 0x00, 0x03, 0x00, 0x04, 0x00, 0x0a, 0x03, 0x00};
    hv_bt_acl_from_guest(&bt, acl_out, sizeof acl_out);
    check("mock received the guest ACL packet", mock.acl_received, 1);
    check("mock received it byte-identical", memcmp(mock.last_acl, acl_out, sizeof acl_out), 0);
    check("mock response queued toward guest", hv_bt_acl_pending(&bt), 1);
    n = hv_bt_take_acl(&bt, ev, sizeof ev);
    check("response acl len", (long)n, 11);
    check("response acl handle", ev[0] | (ev[1] & 0x0f) << 8, 0x0040);
    check("response is ATT read response", ev[8], 0x0b);
    check("response value OK", ev[9] == 'O' && ev[10] == 'K', 1);

    printf("scenario: disconnect\n");
    static const uint8_t discpar[3] = {0x40, 0x00, 0x13};
    n = cmd(&bt, 0x0406, discpar, 3, ev); /* Disconnect */
    check("disconnect first event is cmd status", ev[0], 0x0f);
    check("disconnect status ok", ev[2], 0);
    n = hv_bt_take_event(&bt, ev, sizeof ev);
    check("disconnection complete event len exact", (long)n, 6);
    check("disconnection complete event", ev[0], 0x05);
    check("disconnection complete status ok", ev[2], 0);
    check("disconnection handle matches", ev[3] | ev[4] << 8, 0x0040);
    check("core handle released", bt.le_conn_handle, 0);

    printf("scenario: reconnect allocates a fresh handle\n");
    n = cmd(&bt, 0x200d, connpar, 25, ev);
    n = hv_bt_take_event(&bt, ev, sizeof ev);
    check("second connection handle 0x0041", ev[4] | ev[5] << 8, 0x0041);
    static const uint8_t disc2[3] = {0x41, 0x00, 0x13};
    n = cmd(&bt, 0x0406, disc2, 3, ev);
    n = hv_bt_take_event(&bt, ev, sizeof ev);
    check("second disconnection complete event len exact", (long)n, 6);
    check("second disconnection handle matches", ev[3] | ev[4] << 8, 0x0041);

    printf("test_bt_bridge: %d assertions, %d failures\n", checks, failures);
    printf("%s\n", failures == 0 ? "SCENARIO PASS" : "SCENARIO FAIL");
    return failures != 0;
}
