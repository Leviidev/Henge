/* The xHCI controller's tablet (port 3): its descriptors, its reports and the ports, without a guest.
   The device's file is included so its descriptors and request handler can be checked directly. */
#include "../devices/xhci.c"

#include <stdio.h>

static int failures;
#define CHECK(c)                                                                     \
    do {                                                                             \
        if (!(c)) {                                                                  \
            fprintf(stderr, "test_xhci: FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); \
            failures++;                                                              \
        }                                                                            \
    } while (0)

/* The input report's size in bits, from walking the report descriptor's main and global items. */
static int input_bits(const uint8_t *d, unsigned len) {
    int size = 0, count = 0, bits = 0;
    for (unsigned i = 0; i < len;) {
        uint8_t prefix = d[i];
        unsigned n = prefix & 3;
        if (n == 3) n = 4;
        uint32_t v = 0;
        for (unsigned k = 0; k < n; k++) v |= (uint32_t)d[i + 1 + k] << (8 * k);
        uint8_t tag = prefix & 0xfc;
        if (tag == 0x74) size = (int)v;        /* report size */
        else if (tag == 0x94) count = (int)v;  /* report count */
        else if (tag == 0x80) bits += size * count; /* input */
        i += 1 + n;
    }
    return bits;
}

static int queued(const HvXhci *x) { return (int)(x->tab_rtail - x->tab_rhead); }
static const uint8_t *report(const HvXhci *x, int i) { return x->tab_reports[(x->tab_rhead + (uint32_t)i) % HV_TAB_REPORTS]; }
static int rx(const uint8_t *r) { return r[1] | r[2] << 8; }
static int ry(const uint8_t *r) { return r[3] | r[4] << 8; }

int main(void) {
    HvMachine *m = calloc(1, sizeof *m);
    HvXhci *x = calloc(1, sizeof *x);
    x->m = m;
    pthread_mutex_init(&x->mu, NULL);
    reset(x);

    /* Descriptors: the report is seven bytes, and the configuration says how long the report descriptor is. */
    CHECK(input_bits(tab_report_desc, sizeof tab_report_desc) == 8 * HV_TAB_REPORT_LEN);
    CHECK(tab_config_desc[2] == sizeof tab_config_desc);
    CHECK(tab_config_desc[18 + 7] == sizeof tab_report_desc);
    CHECK(tab_config_desc[9 + 5] == 3 && tab_config_desc[9 + 7] == 0); /* HID, no boot protocol */
    CHECK(input_bits(kbd_report_desc, sizeof kbd_report_desc) == 64); /* the keyboard's, as a check of the walker */

    /* Port 3 is a connected full-speed port, and the Supported Protocol capability covers ports 1-3. */
    CHECK(((x->portsc[2] >> PORT_SPEED_SHIFT) & 0xf) == SPEED_FULL && (x->portsc[2] & PORT_CCS));
    CHECK(((x->portsc[1] >> PORT_SPEED_SHIFT) & 0xf) == SPEED_HIGH);
    CHECK((bar_read(&x->pci, 0, XECP + 8, 4) >> 8 & 0xff) == HV_XHCI_PORTS);
    CHECK((bar_read(&x->pci, 0, 4, 4) >> 24) == HV_XHCI_PORTS);

    /* Requests to a slot holding the tablet. */
    int slot = 3;
    x->slots[slot].dev = 2;
    uint8_t out[256];
    const uint8_t get_device[8] = {0x80, 6, 0, 1, 0, 0, 18, 0};
    CHECK(control(x, slot, get_device, out, 18) == 18 && !memcmp(out, tab_device_desc, 18));
    const uint8_t get_report_desc[8] = {0x81, 6, 0, 0x22, 0, 0, 0xff, 0};
    CHECK(control(x, slot, get_report_desc, out, 255) == (int)sizeof tab_report_desc);
    const uint8_t get_product[8] = {0x80, 6, 2, 3, 0x09, 0x04, 0xff, 0};
    CHECK(control(x, slot, get_product, out, 255) == 2 + 2 * (int)strlen("HengeVM USB Tablet"));

    /* Moves: clamped, and merged while the guest has not taken them. */
    hv_xhci_tablet(x, -5, 40000, 0);
    CHECK(queued(x) == 1 && rx(report(x, 0)) == 0 && ry(report(x, 0)) == HV_TABLET_MAX);
    hv_xhci_tablet(x, 100, 200, 0);
    hv_xhci_tablet(x, 300, 400, 0);
    CHECK(queued(x) == 1 && rx(report(x, 0)) == 300 && ry(report(x, 0)) == 400);
    hv_xhci_tablet(x, 300, 400, 0); /* nothing changed: nothing queued */
    CHECK(queued(x) == 1);

    /* A press keeps its own report at its own place; the drag after it is a new report, then merges. */
    hv_xhci_tablet(x, 300, 400, 1);
    CHECK(queued(x) == 2 && report(x, 1)[0] == 1 && rx(report(x, 1)) == 300);
    hv_xhci_tablet(x, 310, 410, 1);
    CHECK(queued(x) == 3 && rx(report(x, 1)) == 300 && rx(report(x, 2)) == 310);
    hv_xhci_tablet(x, 320, 420, 1);
    CHECK(queued(x) == 3 && rx(report(x, 2)) == 320 && ry(report(x, 2)) == 420);
    hv_xhci_tablet(x, 320, 420, 0);
    CHECK(queued(x) == 4 && report(x, 3)[0] == 0 && rx(report(x, 3)) == 320);

    /* GET_REPORT answers with where it points now. */
    const uint8_t get_report[8] = {0xa1, 1, 0, 1, 0, 0, HV_TAB_REPORT_LEN, 0};
    CHECK(control(x, slot, get_report, out, HV_TAB_REPORT_LEN) == HV_TAB_REPORT_LEN && rx(out) == 320 && out[0] == 0);

    /* Scrolling: a byte a step, so 300 up is three reports, at the current place; a move after one is its own. */
    x->tab_rhead = x->tab_rtail;
    hv_xhci_tablet_scroll(x, -2, 300);
    CHECK(queued(x) == 3);
    CHECK((int8_t)report(x, 0)[5] == 127 && (int8_t)report(x, 1)[5] == 127 && (int8_t)report(x, 2)[5] == 46);
    CHECK((int8_t)report(x, 0)[6] == -2 && (int8_t)report(x, 1)[6] == 0);
    CHECK(rx(report(x, 2)) == 320 && x->tab_state[5] == 0);
    hv_xhci_tablet(x, 330, 420, 0);
    CHECK(queued(x) == 4 && rx(report(x, 3)) == 330 && report(x, 3)[5] == 0);

    /* A full queue drops new reports instead of overwriting waiting ones. */
    x->tab_rhead = x->tab_rtail;
    for (int i = 0; i < HV_TAB_REPORTS + 8; i++) hv_xhci_tablet(x, 0, 0, i & 1);
    CHECK(queued(x) == HV_TAB_REPORTS);

    if (failures) return 1;
    printf("test_xhci: ok\n");
    return 0;
}
