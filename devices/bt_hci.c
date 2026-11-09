#include "bt_hci.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int btlog(void) {
    static int on = -1;
    if (on < 0) on = getenv("HV_BT_LOG") != NULL;
    return on;
}

/* ---- per-machine identity seed -----------------------------------------
   The host supplies the machine UUID's 16 raw bytes before init (see
   hv_bt_set_machine_uuid in bt_hci.h). Process-wide, like the
   personality selection below: this process hosts one machine. All zero
   means no machine identity was supplied, and init then composes the
   fixed per-personality addresses exactly as before. */
static uint8_t bt_machine_uuid[16];
static char bt_derived_serial[13]; /* BCM serial for the seeded address, formatted at init */
static int bt_have_derived_serial;

void hv_bt_set_machine_uuid(const uint8_t uuid[16]) {
    if (uuid) memcpy(bt_machine_uuid, uuid, 16);
    else memset(bt_machine_uuid, 0, 16);
}

static int bt_seed_present(void) {
    for (int i = 0; i < 16; i++)
        if (bt_machine_uuid[i]) return 1;
    return 0;
}

/* The derived address suffix: FNV-1a, 64-bit, over the seed's 16 bytes;
   the low 24 bits, one byte per address octet in display order. A suffix
   of zero, or one equal to either legacy fixed suffix,
   is XORed with 0x000001, so a derived address never reproduces the
   all-installs-identical values it replaces. */
static uint32_t bt_derived_suffix(void) {
    uint64_t h = 14695981039346656037ULL;
    for (int i = 0; i < 16; i++) {
        h ^= bt_machine_uuid[i];
        h *= 1099511628211ULL;
    }
    uint32_t suffix = (uint32_t)(h & 0xffffff);
    if (suffix == 0 || suffix == 0xb20702 || suffix == 0xda7113) suffix ^= 0x000001;
    return suffix;
}

/* ---- personality -------------------------------------------------------
   Default is bcm20702. =csr selects the CSR personality's fixed
   identity bytes. Unknown values fall back to the
   default; the name helper always reports the effective personality. */

HvBtPersonality hv_bt_personality(void) {
    const char *v = getenv("HV_BT_PERSONALITY");
    if (v && (strcmp(v, "csr") == 0 || strcmp(v, "CSR") == 0)) return HV_BT_PERS_CSR;
    return HV_BT_PERS_BCM20702;
}

const char *hv_bt_personality_name(void) {
    return hv_bt_personality() == HV_BT_PERS_CSR ? "csr" : "bcm20702";
}

uint16_t hv_bt_usb_vid(void) {
    return hv_bt_personality() == HV_BT_PERS_CSR ? 0x0a12 : 0x0a5c;
}

uint16_t hv_bt_usb_pid(void) {
    return hv_bt_personality() == HV_BT_PERS_CSR ? 0x0001 : 0x21e8;
}

const char *hv_bt_usb_manufacturer(void) {
    return hv_bt_personality() == HV_BT_PERS_CSR ? "HengeVM" : "Broadcom Corp";
}

const char *hv_bt_usb_product(void) {
    /* "BCM20702A0" is the product string real 0a5c:21e8 dongles report. */
    return hv_bt_personality() == HV_BT_PERS_CSR ? "HengeVM Bluetooth" : "BCM20702A0";
}

const char *hv_bt_usb_serial(void) {
    if (hv_bt_personality() == HV_BT_PERS_CSR) return "1";
    /* Seeded: the serial is the derived BD_ADDR in display hex, formatted
       by hv_bt_init from the composed address. Seedless: the fixed
       identity's serialization. */
    return bt_have_derived_serial ? bt_derived_serial : "001FE1B20702";
}

const char *hv_bt_local_name(void) {
    return hv_bt_personality() == HV_BT_PERS_CSR ? "HengeVM Bluetooth" : "BCM20702A0";
}

/* ---- queues ------------------------------------------------------------ */

static int push_pkt(HvBtPacket *q, uint32_t *head, uint32_t *tail, const uint8_t *data, uint32_t len) {
    if (len > HV_BT_MAX_PACKET) return 0;
    if (*tail - *head >= HV_BT_QUEUE) return 0;
    HvBtPacket *p = &q[*tail % HV_BT_QUEUE];
    memcpy(p->data, data, len);
    p->len = (uint16_t)len;
    (*tail)++;
    return 1;
}

static uint32_t take_pkt(HvBtPacket *q, uint32_t *head, uint32_t *tail, uint8_t *out, uint32_t cap) {
    if (*head == *tail) return 0;
    HvBtPacket *p = &q[*head % HV_BT_QUEUE];
    uint32_t n = p->len < cap ? p->len : cap;
    memcpy(out, p->data, n);
    (*head)++;
    return n;
}

static void queue_event(HvBtHci *bt, const uint8_t *data, uint32_t len) {
    push_pkt(bt->events, &bt->ev_head, &bt->ev_tail, data, len);
}

/* Command Complete: event 0x0e, plen = 4 + return params (num-packets,
   opcode x2, status), num-packets 1. */
static void command_complete(HvBtHci *bt, uint16_t opcode, uint8_t status, const uint8_t *params, uint32_t plen) {
    /* Sized for the largest shaped reply (Read Local Name, 248 bytes). The
       earlier 68-byte buffer overflowed on that command; no test
       issued it, so the defect stayed latent until the BCM suite. */
    uint8_t ev[6 + 248];
    ev[0] = 0x0e;
    ev[1] = (uint8_t)(4 + plen);
    ev[2] = 1;
    ev[3] = (uint8_t)opcode;
    ev[4] = (uint8_t)(opcode >> 8);
    ev[5] = status;
    if (plen) memcpy(ev + 6, params, plen);
    queue_event(bt, ev, 6 + plen);
}

/* Command Status: event 0x0f. */
static void command_status(HvBtHci *bt, uint16_t opcode, uint8_t status) {
    uint8_t ev[6] = {0x0f, 4, status, 1, (uint8_t)opcode, (uint8_t)(opcode >> 8)};
    queue_event(bt, ev, sizeof ev);
}

/* LE Meta event: event 0x3e, first parameter byte is the subevent code. */
static void le_meta_event(HvBtHci *bt, uint8_t subevent, const uint8_t *params, uint32_t plen) {
    uint8_t ev[2 + 1 + 64];
    ev[0] = 0x3e;
    ev[1] = (uint8_t)(1 + plen);
    ev[2] = subevent;
    if (plen) memcpy(ev + 3, params, plen);
    queue_event(bt, ev, 3 + plen);
}

void hv_bt_init(HvBtHci *bt) {
    memset(bt, 0, sizeof *bt);
    bt->personality = hv_bt_personality();
    bt_have_derived_serial = 0;
    if (bt_seed_present()) {
        /* Per-machine address: the low three octets are derived from the
           machine UUID (bt_derived_suffix); the high three stay the
           personality's, with the CSR personality's first display octet
           carrying the locally administered bit (0x02) in place of its
           fixed address's 0x00. The same seed feeds both personalities,
           so one machine keeps one suffix across a personality switch;
           only the high octets change. Wire order is LSB first. */
        uint32_t sfx = bt_derived_suffix();
        if (bt->personality == HV_BT_PERS_BCM20702) {
            const uint8_t addr[6] = {(uint8_t)sfx, (uint8_t)(sfx >> 8), (uint8_t)(sfx >> 16), 0xe1, 0x1f, 0x00};
            memcpy(bt->bd_addr, addr, 6);
            snprintf(bt_derived_serial, sizeof bt_derived_serial, "%02X%02X%02X%02X%02X%02X",
                     bt->bd_addr[5], bt->bd_addr[4], bt->bd_addr[3], bt->bd_addr[2], bt->bd_addr[1], bt->bd_addr[0]);
            bt_have_derived_serial = 1;
        } else {
            const uint8_t addr[6] = {(uint8_t)sfx, (uint8_t)(sfx >> 8), (uint8_t)(sfx >> 16), 0x7d, 0x1a, 0x02};
            memcpy(bt->bd_addr, addr, 6);
        }
    } else if (bt->personality == HV_BT_PERS_BCM20702) {
        /* Broadcom OUI 00:1F:E1 (registered to Broadcom Corp and the OUI
           BCM20702-era USB dongles ship under); the low three octets
           B2:07:02 name the chip so logs and guest UI identify the model.
           Display form 00:1F:E1:B2:07:02; wire order is LSB first. */
        static const uint8_t addr[6] = {0x02, 0x07, 0xb2, 0xe1, 0x1f, 0x00};
        memcpy(bt->bd_addr, addr, 6);
    } else {
        /* A locally administered address in CSR's well-known test range shape;
           wire order is least-significant byte first, as on the HCI. */
        static const uint8_t addr[6] = {0x13, 0x71, 0xda, 0x7d, 0x1a, 0x00}; /* 00:1A:7D:DA:71:13 */
        memcpy(bt->bd_addr, addr, 6);
    }
    bt->loopback = getenv("HV_BT_LOOPBACK") != NULL;
    bt->le_next_handle = 0x0040;
    if (btlog())
        fprintf(stderr, "bt: personality %s (vid %04x pid %04x)\n", hv_bt_personality_name(),
                hv_bt_usb_vid(), hv_bt_usb_pid());
}

void hv_bt_reset(HvBtHci *bt) {
    bt->ev_head = bt->ev_tail = 0;
    bt->acl_head = bt->acl_tail = 0;
    /* Controller state a real reset clears. patchram_launched survives:
       on real BCM silicon the launched patch stays resident across the
       HCI Reset that follows Launch RAM, which is the whole point of
       the download flow. */
    bt->scan_enable = 0;
    bt->le_scan_enabled = 0;
    bt->le_advertising_enabled = 0;
    bt->le_conn_handle = 0;
    bt->patchram_active = 0;
}

/* Broadcom vendor-specific commands (OGF 0x3f, opcodes 0xFC00-0xFCFF).
   Permissive by design: the Broadcom USB transport's patchram flow must
   complete against this RAM stub, so every vendor opcode is accepted
   with a successful Command Complete of the correct shape, the patchram
   opcodes drive the stub's state, and everything is logged under
   HV_BT_LOG so a guest boot shows the exact vendor conversation.
   USB patchram flow (BCM20702): HCI Download Minidriver 0xFC2E, then a
   stream of Write RAM 0xFC4C (4-byte address + data chunk), then Launch
   RAM 0xFC4E (4-byte entry address), then HCI Reset. (0xFC4C is also
   the UART Write RAM opcode; on the USB transport the same opcode
   carries the patchram chunks, there is no separate UART baud step.) */
static void vendor_command(HvBtHci *bt, uint16_t opcode, const uint8_t *par, uint32_t plen) {
    (void)par; /* chunk payloads are counted by length; contents go to the RAM stub */
    bt->vendor_cmds_seen++;
    switch (opcode) {
    case 0xfc01: /* Write BD_ADDR: apply it, do not just ack it */
        if (plen >= 6) memcpy(bt->bd_addr, par, 6);
        if (btlog()) fprintf(stderr, "bt: vendor write bd_addr (applied)\n");
        break;
    case 0xfc2e: /* Download Minidriver: enter patchram download mode */
        bt->patchram_active = 1;
        bt->patchram_bytes = 0;
        if (btlog()) fprintf(stderr, "bt: vendor download minidriver (patchram start)\n");
        break;
    case 0xfc4c: /* Write RAM: 4-byte address + data chunk */
        if (plen > 4) bt->patchram_bytes += plen - 4;
        if (btlog())
            fprintf(stderr, "bt: vendor write ram plen %u (patchram total %llu)\n", plen,
                    (unsigned long long)bt->patchram_bytes);
        break;
    case 0xfc4e: /* Launch RAM: start the downloaded patch */
        bt->patchram_launched = 1;
        bt->patchram_active = 0;
        if (btlog()) fprintf(stderr, "bt: vendor launch ram (patchram running)\n");
        break;
    default:
        if (btlog()) fprintf(stderr, "bt: vendor opcode %04x plen %u (accepted)\n", opcode, plen);
        break;
    }
    command_complete(bt, opcode, 0, NULL, 0);
}

void hv_bt_command(HvBtHci *bt, const uint8_t *pkt, uint32_t len) {
    if (len < 3) return;
    uint16_t opcode = (uint16_t)(pkt[0] | pkt[1] << 8);
    const uint8_t *par = pkt + 3;
    uint32_t plen = pkt[2];
    if ((uint32_t)plen + 3 > len) plen = len - 3;
    bt->commands_seen++;
    if (btlog()) fprintf(stderr, "bt: hci command opcode %04x (ogf %02x ocf %03x) plen %u\n", opcode, opcode >> 10, opcode & 0x3ff, plen);
    /* Vendor-specific OGF 0x3f: the whole 0xFCxx range. */
    if ((opcode & 0xfc00) == 0xfc00) {
        vendor_command(bt, opcode, par, plen);
        return;
    }
    switch (opcode) {
    case 0x0c03: /* HCI_Reset */
        hv_bt_reset(bt);
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x1001: { /* Read Local Version Information */
        if (bt->personality == HV_BT_PERS_BCM20702) {
            /* HCI 4.0 (6), HCI revision 0x1023, LMP 4.0 (6),
               manufacturer 0x000f (Broadcom), LMP subversion 0x220e:
               a BCM20702-consistent 4.0-era version set. */
            static const uint8_t v[8] = {0x06, 0x23, 0x10, 0x06, 0x0f, 0x00, 0x0e, 0x22};
            command_complete(bt, opcode, 0, v, sizeof v);
        } else {
            static const uint8_t v[8] = {0x0b, 0xfb, 0x0d, 0x0b, 0x0a, 0x00, 0x79, 0x0d};
            /* HCI 5.3, rev, LMP 5.3, manufacturer 0x000a (CSR), LMP subversion */
            command_complete(bt, opcode, 0, v, sizeof v);
        }
        break;
    }
    case 0x1002: { /* Read Local Supported Commands: 64-byte bitmap.
                      Conservative: only commands this core honours with
                      correct semantics are claimed (the per-octet
                      derivation follows in this comment).
                      Octet 7 bits 0x01/0x02 (Write Local Name
                      0x0C13, Read Local Name 0x0C14) and octet 17 bit
                      0x02 (Write Extended Inquiry Response 0x0C52) are
                      claimed for the post-init Server.Core chain,
                      which crashes itself (CBCrash) on a synchronous
                      628 for the name write or the EIR write (see
                      the post-init analysis). 0x0C13 and 0x0C52 are
                      pure writes whose full semantics are the default
                      accept-success Command Complete; 0x0C14 has the
                      real shaped case below.
                      Octet 9 bit 0x02 (Write Class of Device
                      0x0C24, desc 0x51, plen 3) is claimed: it is the
                      step immediately after the EIR write inside the
                      EIR completion callback (bluetoothd 0x1005a17ec
                      via composer 0x10018919c and issuer 0x100187b14),
                      its synchronous return is tested by that callback
                      and any nonzero invokes the registered fatal
                      handler; a guest boot died there 17 times (CBCrash reason
                      628) with the bit clear. Pure 3-byte write, full
                      semantics are the default accept-success Command
                      Complete.
                      Octet 7 bit 0x80 (Write Scan Enable 0x0C1A, desc
                      0x47, plen 1) is also claimed: a pure write whose
                      completion callback (0x10018ae10) is bookkeeping
                      only; with the bit clear the discoverability
                      appliers log the 628 and drop it, leaving the
                      guest permanently non-connectable at the HCI
                      level even with the daemon alive. Octet 0 bit
                      0x02 (Inquiry Cancel 0x0402, desc 0x01, plen 0)
                      is claimed so the discovery state machine cancel
                      path completes like silicon; 0x0401 Inquiry
                      itself was already claimed (bit 0x01) and has
                      the real case below (Command Status, then
                      Inquiry Complete with no results).
                      Octet 7 bit 0x40 (Read Scan Enable 0x0C19,
                      desc 0x46, plen 0) is claimed: the disco state
                      sync reads the controller's scan byte before any
                      Write Scan Enable, and with the bit clear the
                      read's synchronous 628 aborted both
                      discoverability appliers before 0x0C1A was ever
                      issued (observed failure: "Failed to make local device
                      discoverable with result 628"). The reply is
                      shaped from the real tracked register (the
                      scan_enable field: power-on 0x00, replaced by
                      every 0x0C1A write, cleared by HCI Reset),
                      exactly status + 1 byte like silicon; the
                      completion callback readScanEnableCb
                      (0x100188568) consumes that one byte by value.
                      Octet 11 bit 0x10 (Write Current IAC LAP 0x0C3A,
                      desc 0x64) is claimed: it is the FIRST step of
                      the discoverability policy applier (0x1001888E0),
                      whose synchronous dispatcher return aborts the
                      whole WriteDiscoverability application before
                      the read is reached, so claiming the read alone
                      would leave discoverability dead at its head.
                      Pure write (1 + 3n bytes); full semantics are
                      the default accept-success Command Complete
                      (this core never answers an inquiry with a
                      result, so no IAC state is observable). Octet 37
                      bits 0x20/0x40 (LE Set Extended Scan Parameters
                      0x2041 desc 0xD7, LE Set Extended Scan Enable
                      0x2042 desc 0xD8) are claimed: the daemon's LE
                      layer selects the extended setters from its
                      internal capability cache (shared with extended
                      advertising; no served feature bit was traced
                      to that selection),
                      and with the bits clear every LE scan start
                      died at the params step with 628 (25 refusals
                      in one boot). 0x2041 is a pure parameter state write
                      served by the default accept-success Command
                      Complete (the core retains no scan parameters,
                      exactly as for classic 0x200B); 0x2042 has the
                      real case below tracking le_scan_enabled from
                      its Enable byte, mirroring 0x200C, so the
                      advertising-report injector gate stays truthful.
                      No scan result is ever fabricated. The extended
                      ADVERTISING setters (octet 36 and the rest of
                      octet 37) stay unclaimed: no advertising-set
                      command crossed the wire and their
                      parameter state is real payload this core does
                      not model. */
        static const uint8_t c[64] = {
            0x23, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x00, 0xc3,
            0x00, 0x02, 0x60, 0x10, 0x00, 0x00, 0xf8, 0x03,
            0x00, 0x42, 0x08, 0x00, 0x00, 0x00, 0x04, 0x00,
            0x40, 0xb7, 0x7f, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00,
            0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        };
        command_complete(bt, opcode, 0, c, sizeof c);
        break;
    }
    case 0x1003: { /* Read Local Supported Features */
        static const uint8_t f[8] = {0xff, 0xff, 0x8f, 0xfe, 0xdb, 0xff, 0x5b, 0x87};
        command_complete(bt, opcode, 0, f, sizeof f);
        break;
    }
    case 0x1004: { /* Read Local Extended Features: plen 1 (Page_Number).
                      Reply: Page_Number echo, Maximum_Page_Number, and the
                      8-byte Extended_LMP_Features of the requested page.
                      The guest's OI layer refuses to ISSUE this
                      command unless the 0x1002 mask claims it (octet 14
                      bit 6, 0x40); with the bit clear the send fails
                      locally with OI status 628 and the dongle init aborts
                      before anything reaches the wire (see
                      the extended-features analysis). Pages: 0 carries no extended
                      LMP bits beyond the 0x1003 page; 1 carries the LE
                      host-support bits matching the LE features served at
                      0x2003 (byte 0 bit 0 LE Supported (Host), bit 1
                      Simultaneous LE+BR/EDR (Host)); 2, the page the
                      guest's init requests, carries no bits. A page above
                      the maximum returns the spec error 0x11. */
        static const uint8_t pages[3][8] = {
            {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
            {0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
            {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
        };
        uint8_t page = plen >= 1 ? par[0] : 0;
        if (page > 2) {
            command_complete(bt, opcode, 0x11, NULL, 0);
        } else {
            uint8_t r[10];
            r[0] = page;
            r[1] = 2; /* Maximum_Page_Number */
            memcpy(r + 2, pages[page], 8);
            command_complete(bt, opcode, 0, r, sizeof r);
        }
        break;
    }
    case 0x1005: { /* Read Buffer Size: ACL 1021 x4, SCO 64 x4 (USB-friendly) */
        static const uint8_t b[7] = {0xfd, 0x03, 0x40, 0x04, 0x00, 0x04, 0x00};
        command_complete(bt, opcode, 0, b, sizeof b);
        break;
    }
    case 0x1009: /* Read BD_ADDR: bd_addr is stored wire-order (LSB first) */
        command_complete(bt, opcode, 0, bt->bd_addr, 6);
        break;
    case 0x0c14: { /* Read Local Name */
        uint8_t name[248];
        memset(name, 0, sizeof name);
        const char *n = bt->personality == HV_BT_PERS_BCM20702 ? "BCM20702A0" : "HengeVM Bluetooth";
        memcpy(name, n, strlen(n));
        command_complete(bt, opcode, 0, name, sizeof name);
        break;
    }
    case 0x0c19: /* Read Scan Enable: status + the tracked scan byte.
                    readScanEnableCb (bluetoothd 0x100188568)
                    consumes exactly this one byte, delivered by value;
                    real BCM20702 silicon returns exactly status + 1
                    byte. The byte is the core's real register: 0x00 at
                    power-on and after HCI Reset, replaced by every
                    Write Scan Enable below. */
        command_complete(bt, opcode, 0, &bt->scan_enable, 1);
        break;
    case 0x0c1a: /* Write Scan Enable: store the register, then succeed.
                    Claiming this bit was not enough while
                    the state-sync read above was unservable; with both
                    served the disco appliers run their full pass. */
        if (plen >= 1) bt->scan_enable = par[0];
        if (btlog()) fprintf(stderr, "bt: scan enable %02x\n", bt->scan_enable);
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x2002: { /* LE Read Buffer Size [v1] */
        static const uint8_t b[3] = {0xfb, 0x00, 0x08}; /* 251-byte LE ACL x8 */
        command_complete(bt, opcode, 0, b, sizeof b);
        break;
    }
    case 0x2003: { /* LE Read Local Supported Features */
        static const uint8_t f[8] = {0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}; /* encryption + conn param req */
        command_complete(bt, opcode, 0, f, sizeof f);
        break;
    }
    case 0x200f: { /* LE Read Filter Accept List Size: 1 byte.
                      The guest wrapper for this step (descriptor
                      0xAF) passes a synchronous dispatcher failure to the
                      init failure handler with no 628 tolerance, so the
                      clear mask bit was fatal at the wrapper level even
                      though the completion callback converts failure to 0
                      (see the init-sequence analysis). The reply is the real
                      capacity of the accept list this core services: the
                      core accepts LE accept-list writes by default, and
                      16 entries is the BCM20702-class capacity. */
        static const uint8_t s[1] = {0x10}; /* 16 entries */
        command_complete(bt, opcode, 0, s, sizeof s);
        break;
    }
    case 0x2060: { /* LE Read Buffer Size V2: LE ACL u16 + LE ACL count u8
                      + LE ISO u16 + LE ISO count u8 after the status.
                      the guest selects V2 over V1 from LE features byte 3
                      (>= 0x10), which the served 0x2003 reply keeps at 0,
                      but the V2 completion callback is raw-status and its
                      parser (readLEBufferSizeV2CB) synthesizes status 605
                      when fewer than 6 return bytes follow the status, so
                      the default empty success would be fatal if the
                      branch were ever taken. ACL values repeat the 0x2002
                      story exactly (251 x8); ISO values are zero: this
                      core has no ISO datapath, matching the BT 4.0-era
                      feature set served at 0x2003. */
        static const uint8_t b[6] = {0xfb, 0x00, 0x08, 0x00, 0x00, 0x00};
        command_complete(bt, opcode, 0, b, sizeof b);
        break;
    }
    case 0x2005: /* LE Set Random Address: a write; status-only reply, address stored */
        if (plen >= 6) memcpy(bt->le_random_addr, par, 6);
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x201c: { /* LE Read Supported States: 8 bytes, broad state support */
        static const uint8_t s[8] = {0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00, 0x00};
        command_complete(bt, opcode, 0, s, sizeof s);
        break;
    }
    case 0x200b: /* LE Set Scan Parameters: accept and remember nothing critical */
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x200c: /* LE Set Scan Enable: param 0 = enable, 1 = filter duplicates */
        bt->le_scan_enabled = plen >= 1 ? par[0] != 0 : 0;
        if (btlog()) fprintf(stderr, "bt: le scan %s\n", bt->le_scan_enabled ? "enabled" : "disabled");
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x2041: /* LE Set Extended Scan Parameters: a pure parameter
                    state write; the core retains no scan parameters
                    (exactly as for classic 0x200B), so the accept-success
                    Command Complete is its full spec semantics.
                    claimed because the daemon's LE layer selects this
                    setter from its capability cache and a clear bit made
                    every scan start refuse with 628 at this step (see
                    the scan-fix analysis). */
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x2042: /* LE Set Extended Scan Enable: param 0 = enable,
                    1 = filter duplicates, 2-3 = duration, 4-5 = period.
                    The spec completion is a status-only Command
                    Complete. Tracks le_scan_enabled exactly as 0x200C
                    does, so the advertising-report injector gate stays
                    truthful. */
        bt->le_scan_enabled = plen >= 1 ? par[0] != 0 : 0;
        if (btlog()) fprintf(stderr, "bt: le ext scan %s\n", bt->le_scan_enabled ? "enabled" : "disabled");
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x200a: /* LE Set Advertise Enable (guest-peripheral role) */
        bt->le_advertising_enabled = plen >= 1 ? par[0] != 0 : 0;
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x200d: { /* LE Create Connection */
        command_status(bt, opcode, 0);
        /* Params: scan interval(2) window(2) filter(1) peer addr type(1)
           peer addr(6) own addr type(1) interval min(2) max(2) latency(2)
           supervision timeout(2) CE length min(2) max(2) = 25 bytes. */
        uint8_t peer_type = plen >= 6 ? par[5] : 0;
        uint8_t peer[6] = {0, 0, 0, 0, 0, 0};
        if (plen >= 12) memcpy(peer, par + 6, 6);
        uint16_t interval = plen >= 17 ? (uint16_t)(par[15] | par[16] << 8) : 0x0028;
        uint16_t latency = plen >= 19 ? (uint16_t)(par[17] | par[18] << 8) : 0;
        uint16_t supto = plen >= 21 ? (uint16_t)(par[19] | par[20] << 8) : 0x01f4;
        uint16_t handle = bt->le_next_handle++;
        bt->le_conn_handle = handle;
        bt->le_peer_addr_type = peer_type;
        memcpy(bt->le_peer_addr, peer, 6);
        bt->le_scan_enabled = 0; /* creating a connection ends scanning, as on silicon */
        uint8_t cp[18];
        cp[0] = 0; /* status */
        cp[1] = (uint8_t)handle;
        cp[2] = (uint8_t)(handle >> 8);
        cp[3] = 0; /* role: central */
        cp[4] = peer_type;
        memcpy(cp + 5, peer, 6);
        cp[11] = (uint8_t)interval;
        cp[12] = (uint8_t)(interval >> 8);
        cp[13] = (uint8_t)latency;
        cp[14] = (uint8_t)(latency >> 8);
        cp[15] = (uint8_t)supto;
        cp[16] = (uint8_t)(supto >> 8);
        cp[17] = 0; /* central clock accuracy */
        le_meta_event(bt, 0x01, cp, sizeof cp); /* LE Connection Complete */
        if (btlog()) fprintf(stderr, "bt: le connection complete handle %04x\n", handle);
        break;
    }
    case 0x200e: /* LE Create Connection Cancel */
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    case 0x0401: /* Inquiry: status now, complete with no results */
        command_status(bt, opcode, 0);
        {
            uint8_t ev[3] = {0x01, 1, 0}; /* Inquiry Complete, status 0 */
            queue_event(bt, ev, sizeof ev);
        }
        break;
    case 0x0409: /* Create Connection: no backend peer is attached */
        command_status(bt, opcode, 0x25); /* Synchronous Connection Limit Exceeded... closest honest refusal */
        break;
    case 0x0406: { /* Disconnect */
        command_status(bt, opcode, 0);
        uint16_t handle = plen >= 2 ? (uint16_t)(par[0] | par[1] << 8) : 0;
        if (handle == bt->le_conn_handle) bt->le_conn_handle = 0;
        uint8_t ev[6] = {0x05, 4, 0, par[0], par[1], 0x16}; /* Disconnection Complete */
        queue_event(bt, ev, sizeof ev);
        break;
    }
    default:
        /* Everything else (event masks, LE masks, page timeout, class of
           device, LE advertising parameter/data setters, ...): accept and
           report success. The boot log records each opcode, so a stack
           that needs a shaped reply is visible rather than silently
           stalled. */
        command_complete(bt, opcode, 0, NULL, 0);
        break;
    }
}

int hv_bt_backend_inject_adv_report(HvBtHci *bt, uint8_t addr_type, const uint8_t addr[6],
                                    int8_t rssi, const uint8_t *adv_data, uint32_t adv_len) {
    if (!bt->le_scan_enabled) return 0;
    if (adv_len > 31) adv_len = 31;
    uint8_t p[1 + 1 + 1 + 6 + 1 + 31 + 1];
    uint32_t n = 0;
    p[n++] = 0x01; /* Num_Reports */
    p[n++] = 0x00; /* event type: ADV_IND (connectable, undirected) */
    p[n++] = addr_type;
    memcpy(p + n, addr, 6);
    n += 6;
    p[n++] = (uint8_t)adv_len;
    if (adv_len) memcpy(p + n, adv_data, adv_len);
    n += adv_len;
    p[n++] = (uint8_t)rssi;
    le_meta_event(bt, 0x02, p, n); /* LE Advertising Report, one report */
    if (btlog()) fprintf(stderr, "bt: le adv report injected (rssi %d, data %u)\n", rssi, adv_len);
    return 1;
}

void hv_bt_set_acl_sink(HvBtHci *bt, HvBtAclSink sink, void *ctx) {
    bt->acl_sink = sink;
    bt->acl_sink_ctx = ctx;
}

void hv_bt_acl_from_guest(HvBtHci *bt, const uint8_t *pkt, uint32_t len) {
    bt->acl_from_guest++;
    if (btlog()) fprintf(stderr, "bt: acl from guest len %u handle %u\n", len, len >= 2 ? (pkt[0] | (pkt[1] & 0x0f) << 8) : 0);
    if (bt->acl_sink) {
        bt->acl_sink(bt->acl_sink_ctx, pkt, len);
        return;
    }
    if (bt->loopback && len) {
        if (push_pkt(bt->acl_in, &bt->acl_head, &bt->acl_tail, pkt, len)) bt->acl_to_guest++;
    }
}

void hv_bt_sco_from_guest(HvBtHci *bt, const uint8_t *pkt, uint32_t len) {
    (void)pkt;
    bt->sco_from_guest++;
    if (btlog()) fprintf(stderr, "bt: sco from guest len %u (sink)\n", len);
}

int hv_bt_inject_acl(HvBtHci *bt, const uint8_t *pkt, uint32_t len) {
    int ok = push_pkt(bt->acl_in, &bt->acl_head, &bt->acl_tail, pkt, len);
    if (ok) bt->acl_to_guest++;
    return ok;
}

uint32_t hv_bt_take_event(HvBtHci *bt, uint8_t *out, uint32_t cap) {
    return take_pkt(bt->events, &bt->ev_head, &bt->ev_tail, out, cap);
}

uint32_t hv_bt_take_acl(HvBtHci *bt, uint8_t *out, uint32_t cap) {
    return take_pkt(bt->acl_in, &bt->acl_head, &bt->acl_tail, out, cap);
}

int hv_bt_event_pending(HvBtHci *bt) {
    return bt->ev_head != bt->ev_tail;
}

int hv_bt_acl_pending(HvBtHci *bt) {
    return bt->acl_head != bt->acl_tail;
}
