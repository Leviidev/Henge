#ifndef HENGEVM_BT_HCI_H
#define HENGEVM_BT_HCI_H

#include <stdint.h>

/* A minimal Bluetooth HCI controller core (USB transport lives in xhci.c).
   Implements the command surface a host stack
   needs to enumerate and bring up a controller (reset, version, features,
   buffer sizes, masks, name, inquiry) and accepts everything else with a
   successful Command Complete, logging every opcode so a guest boot shows
   exactly what the guest stack asked for (HV_BT_LOG=1).

   The controller personality is selectable
   with HV_BT_PERSONALITY=csr|bcm20702 (default bcm20702). The BCM20702
   personality impersonates the Broadcom USB dongle macOS's
   BroadcomBluetoothHostControllerUSBTransport explicitly lists
   (VID 0x0a5c, PID 0x21e8): Broadcom HCI identity (manufacturer 0x000f,
   HCI/LMP 4.0), a Broadcom-OUI BD_ADDR, a Broadcom local name, and a
   permissive Broadcom vendor-command handler so the patchram firmware
   upload flow (Download Minidriver 0xFC2E, Write RAM 0xFC4C, Launch RAM
   0xFC4E, and any other 0xFCxx) completes against a RAM stub instead of
   erroring. Under =csr every identity byte is the fixed CSR value.

   The core also adds the minimal LE command/event synthesis the
   CoreBluetooth bridge needs (LE Set Scan Parameters / Enable, LE
   Create Connection, LE advertising for the guest-peripheral role) and
   the backend seam for it: hv_bt_backend_inject_adv_report() lets a
   backend deliver a discovered peripheral as an LE Advertising Report,
   and hv_bt_set_acl_sink() routes guest ACL data to a backend (the
   CoreBluetooth bridge on device, a mock in tests/test_bt_bridge.c).

   The core is transport-pure: the caller feeds HCI command packets (the
   3-byte header + parameters that arrive on the USB control pipe) and ACL
   data packets from the guest, and drains HCI event packets and ACL data
   packets toward the guest. */

#define HV_BT_MAX_PACKET 1056
#define HV_BT_QUEUE 64

typedef enum HvBtPersonality {
    HV_BT_PERS_CSR = 0,
    HV_BT_PERS_BCM20702 = 1,
} HvBtPersonality;

/* Personality selection: HV_BT_PERSONALITY=csr|bcm20702, default bcm20702.
   Read from the environment on every call so tests can switch per core. */
HvBtPersonality hv_bt_personality(void);
const char *hv_bt_personality_name(void);
/* USB identity for the active personality (consumed by xhci.c). */
uint16_t hv_bt_usb_vid(void);
uint16_t hv_bt_usb_pid(void);
const char *hv_bt_usb_manufacturer(void);
const char *hv_bt_usb_product(void);
const char *hv_bt_usb_serial(void);
/* HCI Read Local Name payload for the active personality. */
const char *hv_bt_local_name(void);

typedef struct HvBtPacket {
    uint16_t len;
    uint8_t data[HV_BT_MAX_PACKET];
} HvBtPacket;

/* Backend ACL sink: guest ACL data the core cannot answer locally is
   delivered here (CoreBluetooth bridge on device, mock in the harness). */
typedef void (*HvBtAclSink)(void *ctx, const uint8_t *pkt, uint32_t len);

typedef struct HvBtHci {
    HvBtPacket events[HV_BT_QUEUE];
    uint32_t ev_head, ev_tail;
    HvBtPacket acl_in[HV_BT_QUEUE]; /* backend -> guest */
    uint32_t acl_head, acl_tail;
    uint8_t bd_addr[6];
    uint64_t commands_seen, acl_from_guest, acl_to_guest, sco_from_guest;
    int loopback;
    HvBtPersonality personality;
    /* Broadcom vendor / patchram state (BCM personality; counters are
       maintained under CSR too so tests can prove the handler is inert
       there only in the sense that no guest sends the flow). */
    uint64_t vendor_cmds_seen;
    int patchram_active;    /* Download Minidriver seen, no Launch yet */
    int patchram_launched;  /* Launch RAM seen: stub firmware is "running" */
    uint64_t patchram_bytes; /* payload bytes accepted via Write RAM */
    /* BR/EDR scan-enable state (the Write Scan Enable 0x0C1A
       register): the byte Read Scan Enable 0x0C19 reports. Power-on
       and HCI Reset default is 0x00 (neither inquiry scan nor page
       scan), as on silicon; every 0x0C1A write replaces it. */
    uint8_t scan_enable;
    /* LE state for the bridge. */
    int le_scan_enabled;
    int le_advertising_enabled;
    uint16_t le_next_handle; /* next LE connection handle to allocate */
    uint16_t le_conn_handle; /* live LE connection handle, or 0 */
    uint8_t le_peer_addr[6];
    uint8_t le_peer_addr_type;
    uint8_t le_random_addr[6]; /* LE Set Random Address (0x2005) stored address */
    HvBtAclSink acl_sink;
    void *acl_sink_ctx;
} HvBtHci;

void hv_bt_init(HvBtHci *bt);
void hv_bt_reset(HvBtHci *bt);
/* One HCI command packet from the guest (opcode little-endian in bytes 0-1,
   parameter length in byte 2). Queues the resulting event(s). */
void hv_bt_command(HvBtHci *bt, const uint8_t *pkt, uint32_t len);
/* One HCI ACL data packet from the guest (4-byte header + payload). */
void hv_bt_acl_from_guest(HvBtHci *bt, const uint8_t *pkt, uint32_t len);
/* One HCI SCO data packet from the guest (3-byte header + payload). */
void hv_bt_sco_from_guest(HvBtHci *bt, const uint8_t *pkt, uint32_t len);
/* Backend side: queue one ACL data packet for the guest. */
int hv_bt_inject_acl(HvBtHci *bt, const uint8_t *pkt, uint32_t len);
/* Backend side: install (or clear, with NULL) the guest-ACL sink. When a
   sink is installed it replaces loopback echo as the ACL data path. */
void hv_bt_set_acl_sink(HvBtHci *bt, HvBtAclSink sink, void *ctx);
/* Backend side: report one discovered BLE peripheral to the guest as an
   LE Advertising Report meta event. Synthesized only while the guest has
   LE scanning enabled; returns 1 when an event was queued, else 0.
   addr is in HCI wire order (least-significant byte first). adv_data is
   the raw AD-structure payload (may be NULL when adv_len is 0). */
int hv_bt_backend_inject_adv_report(HvBtHci *bt, uint8_t addr_type, const uint8_t addr[6],
                                    int8_t rssi, const uint8_t *adv_data, uint32_t adv_len);
/* Drain: copy the next queued event / ACL packet into out (capacity cap);
   returns its length, or 0 when the queue is empty. */
uint32_t hv_bt_take_event(HvBtHci *bt, uint8_t *out, uint32_t cap);
uint32_t hv_bt_take_acl(HvBtHci *bt, uint8_t *out, uint32_t cap);
int hv_bt_event_pending(HvBtHci *bt);
int hv_bt_acl_pending(HvBtHci *bt);

#endif
