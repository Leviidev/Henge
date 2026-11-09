/* Device-tree plant core: insert the 14-byte
   bluetoothInternalControllerInfo property into the ADT /options node.
   Header-only and dependency-free so the exact code linked into hengevm
   (via host/vm.c) is also what tests/test_dtplant.c exercises, against
   the synthetic ADT fixture in tests/fixtures (a generated blob built
   from the format definition below). Pure buffer operations: no I/O,
   no allocation; every failure returns 0 with *reason set and the
   buffer byte-identical to its input (the one write path rolls back
   if its post-insert re-walk fails). The one piece of state is the
   machine-identity seed below, set by the host before any insert,
   process-wide like the HCI core's seed: this process hosts one
   machine. The planted value's identity bytes are derived from that
   seed, so no fixed internal-controller identity is ever served.
   ADT format (the definition the fixture is generated from):
     node     := u32 nProperties, u32 nChildren, properties, children
     property := char name[32] (NUL-padded), u32 length, value bytes
                 padded up to a 4-byte multiple. The length word's TOP
                 BIT is a flag (syscfg string properties carry it); the
                 value size is length & 0x7fffffff. Advance = 36 +
                 ROUND_UP(size, 4).
   The plant property is a plain data property: length word 14, flag
   clear, matching the format's plain data properties. */
#ifndef HENGE_DTPLANT_H
#define HENGE_DTPLANT_H

#include <stdint.h>
#include <string.h>

#define DTPLANT_PROP_NAME "bluetoothInternalControllerInfo"
#define DTPLANT_PAYLOAD_LEN 14
#define DTPLANT_ENTRY_SIZE 52 /* 32 name + 4 length + 16 (14 padded to 4) */
#define DTPLANT_PAGE 16384u /* iBoot pads the in-RAM tree to its last 16 KiB page (QEMU vmapple precedent) */

/* ---- per-machine identity seed -----------------------------------------
   The host supplies the machine UUID's 16 raw bytes before any insert
   (dtplant_set_machine_uuid). All zero means no machine identity was
   supplied; insert then fails clean (below), because the payload's
   identity bytes are derived from the seed and there is no fixed
   identity to fall back to. */
static uint8_t dtplant_seed[16];

static inline void dtplant_set_machine_uuid(const uint8_t uuid[16]) {
    if (uuid) memcpy(dtplant_seed, uuid, 16);
    else memset(dtplant_seed, 0, 16);
}

static inline int dtplant_seed_present(void) {
    for (int i = 0; i < 16; i++)
        if (dtplant_seed[i]) return 1;
    return 0;
}

/* The derived internal-address suffix: FNV-1a, 64-bit, over the seed's
   16 bytes; the low 24 bits, one byte per address octet, composed
   exactly as the HCI core composes its derived suffix. The guards are
   the core's (a zero suffix, or one equal to either legacy fixed
   controller suffix, is XORed with 0x000001), plus one more: a result
   equal to the legacy fixed internal suffix this derivation replaces
   is XORed with 0x010100, so the plant never serves that fixed
   identity, including via the zero-suffix guard's own mapping. */
static inline uint32_t dtplant_derived_suffix(void) {
    uint64_t x = 14695981039346656037ULL;
    for (int i = 0; i < 16; i++) {
        x ^= dtplant_seed[i];
        x *= 1099511628211ULL;
    }
    uint32_t suffix = (uint32_t)(x & 0xffffff);
    if (suffix == 0 || suffix == 0xb20702 || suffix == 0xda7113) suffix ^= 0x000001;
    if (suffix == 0x000001) suffix ^= 0x010100;
    return suffix;
}

/* Build the 14-byte payload: the leading eight bytes stay the
   format's zero prefix; the last six are the internal address in HCI
   wire order (LSB first): the high three display octets stay
   F0:18:98, the low three are the derived suffix. */
static inline void dtplant_build_payload(uint8_t out[DTPLANT_PAYLOAD_LEN]) {
    memset(out, 0, DTPLANT_PAYLOAD_LEN);
    uint32_t sfx = dtplant_derived_suffix();
    out[8] = (uint8_t)sfx;
    out[9] = (uint8_t)(sfx >> 8);
    out[10] = (uint8_t)(sfx >> 16);
    out[11] = 0x98;
    out[12] = 0x18;
    out[13] = 0xF0;
}

static inline uint32_t dtplant_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline void dtplant_wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

typedef struct {
    uint32_t nodes, props;
    int have_options;
    uint64_t options_hdr; /* offset of the /options node header */
    uint64_t options_insert; /* offset just past its last property */
    uint32_t options_nprops;
    int target_present; /* the plant property already in /options */
    uint64_t target_val_off;
    uint32_t target_vlen;
} DtplantInfo;

typedef struct {
    const uint8_t *buf;
    uint32_t len;
    const char *reason;
    DtplantInfo info;
} DtplantWalk;

/* Walk one node at off (recursively its children). Returns 1 and the
   offset just past the node, or 0 with w->reason set. Validates every
   structural field it touches against w->len. */
static int dtplant_walk_node(DtplantWalk *w, uint64_t off, int depth, uint64_t *end_out) {
    if (depth > 32) { w->reason = "adt depth implausible"; return 0; }
    if (++w->info.nodes > 4096) { w->reason = "adt node count implausible"; return 0; }
    if (off + 8 > w->len) { w->reason = "adt node header out of bounds"; return 0; }
    uint32_t nprops = dtplant_rd32(w->buf + off);
    uint32_t nchild = dtplant_rd32(w->buf + off + 4);
    if (nprops > 4096 || nchild > 1024) { w->reason = "adt node counts implausible"; return 0; }
    uint64_t hdr = off;
    off += 8;
    char node_name[64];
    node_name[0] = 0;
    int tgt_here = 0;
    uint64_t tgt_val = 0;
    uint32_t tgt_len = 0;
    for (uint32_t i = 0; i < nprops; i++) {
        if (++w->info.props > 65536) { w->reason = "adt property count implausible"; return 0; }
        if (off + 36 > w->len) { w->reason = "adt property header out of bounds"; return 0; }
        const uint8_t *nm = w->buf + off;
        if (!nm[0] || !memchr(nm, 0, 32)) { w->reason = "adt property name malformed"; return 0; }
        uint32_t vlen = dtplant_rd32(w->buf + off + 32) & 0x7fffffffu; /* top bit is a flag */
        if (off + 36 + vlen > w->len) { w->reason = "adt property value out of bounds"; return 0; }
        if (!strcmp((const char *)nm, "name")) {
            if (vlen && vlen < sizeof(node_name)) {
                memcpy(node_name, w->buf + off + 36, vlen);
                node_name[vlen] = 0;
                node_name[strcspn(node_name, "\0")] = 0;
            }
        } else if (!strcmp((const char *)nm, DTPLANT_PROP_NAME)) {
            tgt_here = 1;
            tgt_val = off + 36;
            tgt_len = vlen;
        }
        off += 36 + ((vlen + 3u) & ~3u);
    }
    if (depth == 1 && !strcmp(node_name, "options")) {
        if (w->info.have_options) { w->reason = "multiple options nodes"; return 0; }
        w->info.have_options = 1;
        w->info.options_hdr = hdr;
        w->info.options_insert = off;
        w->info.options_nprops = nprops;
        if (tgt_here) {
            w->info.target_present = 1;
            w->info.target_val_off = tgt_val;
            w->info.target_vlen = tgt_len;
        }
    }
    for (uint32_t i = 0; i < nchild; i++) {
        if (!dtplant_walk_node(w, off, depth + 1, &off)) return 0;
    }
    *end_out = off;
    return 1;
}

/* Validate the whole blob and fill *info. Returns 1 iff the walk
   consumes exactly len bytes. */
static int dtplant_inspect(const uint8_t *buf, uint32_t len, DtplantInfo *info, const char **reason) {
    DtplantWalk w;
    memset(&w, 0, sizeof(w));
    w.buf = buf;
    w.len = len;
    uint64_t end = 0;
    if (!dtplant_walk_node(&w, 0, 0, &end)) { *reason = w.reason; return 0; }
    if (end != len) { *reason = "adt walk does not consume the blob exactly"; return 0; }
    *info = w.info;
    return 1;
}

/* Insert the plant property at the end of /options' property list.
   buf holds len valid bytes inside an allocation of bound bytes.
   Returns 1 on insert (*new_len_out = len + 52), 2 if the property is
   already present with the exact payload (buffer untouched), or 0 on
   any validation or capacity failure (buffer untouched, *reason set).
   Capacity is PROVEN, never assumed: the bytes from len up to the end
   of the containing 16 KiB page must all lie inside bound, number at
   least 52, and be zero-filled; anything else is a clean failure. */
static int dtplant_insert(uint8_t *buf, uint32_t len, uint64_t bound, uint32_t *new_len_out, const char **reason) {
    if (!buf || len < 8 || (uint64_t)len > bound) { *reason = "adt blob out of allocation bounds"; return 0; }
    if (!dtplant_seed_present()) { *reason = "no machine identity supplied for the plant payload"; return 0; }
    uint8_t dtplant_payload[DTPLANT_PAYLOAD_LEN];
    dtplant_build_payload(dtplant_payload);
    DtplantInfo info;
    if (!dtplant_inspect(buf, len, &info, reason)) return 0;
    if (!info.have_options) { *reason = "options node not found"; return 0; }
    if (info.target_present) {
        if (info.target_vlen == DTPLANT_PAYLOAD_LEN && !memcmp(buf + info.target_val_off, dtplant_payload, DTPLANT_PAYLOAD_LEN)) return 2;
        *reason = "property already present with a different value";
        return 0;
    }
    uint64_t page_end = ((uint64_t)len + DTPLANT_PAGE - 1) & ~(uint64_t)(DTPLANT_PAGE - 1);
    if (page_end > bound) { *reason = "capacity unprovable: page end beyond allocation"; return 0; }
    if (page_end - len < DTPLANT_ENTRY_SIZE) { *reason = "capacity unprovable: page slack under 52 bytes"; return 0; }
    for (uint64_t i = len; i < page_end; i++)
        if (buf[i]) { *reason = "capacity unprovable: page slack not zero-filled"; return 0; }
    uint64_t at = info.options_insert;
    memmove(buf + at + DTPLANT_ENTRY_SIZE, buf + at, len - at);
    uint8_t entry[DTPLANT_ENTRY_SIZE];
    memset(entry, 0, sizeof(entry));
    memcpy(entry, DTPLANT_PROP_NAME, sizeof(DTPLANT_PROP_NAME) - 1); /* 31 chars + NUL in the 32-byte field */
    dtplant_wr32(entry + 32, DTPLANT_PAYLOAD_LEN);
    memcpy(entry + 36, dtplant_payload, DTPLANT_PAYLOAD_LEN);
    memcpy(buf + at, entry, DTPLANT_ENTRY_SIZE);
    dtplant_wr32(buf + info.options_hdr, info.options_nprops + 1);
    /* Post-insert re-walk of the grown blob; roll back on any surprise. */
    DtplantInfo chk;
    const char *vr = NULL;
    uint32_t nl = len + DTPLANT_ENTRY_SIZE;
    if (!dtplant_inspect(buf, nl, &chk, &vr) || !chk.have_options || !chk.target_present ||
        chk.target_vlen != DTPLANT_PAYLOAD_LEN || memcmp(buf + chk.target_val_off, dtplant_payload, DTPLANT_PAYLOAD_LEN) ||
        chk.options_nprops != info.options_nprops + 1 || chk.props != info.props + 1) {
        memmove(buf + at, buf + at + DTPLANT_ENTRY_SIZE, len - at);
        dtplant_wr32(buf + info.options_hdr, info.options_nprops);
        *reason = "post-insert verify failed (rolled back)";
        return 0;
    }
    *new_len_out = nl;
    return 1;
}

#endif /* HENGE_DTPLANT_H */
