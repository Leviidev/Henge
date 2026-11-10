/* Host-side ADT plant test: runs the exact dtplant.h code hengevm
   links (via host/vm.c) against an ADT blob: the synthetic fixture
   in tests/fixtures, generated from the dtplant.h format definition.
   Usage: test_dtplant <adt.bin>
   Checks: with no machine identity supplied, insert fails clean with
   the buffer untouched (the payload's identity is derived, never
   fixed); with the fixture identity supplied, insert lands the exact
   52-byte entry in /options carrying that identity's derived payload,
   every other byte identical, total length +52, re-walk consumes the
   grown blob; second insert is a no-op already-present; truncated /
   poisoned-slack / short-allocation inputs fail clean with the buffer
   untouched. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dtplant.h"

static int fails;
#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: test_dtplant <adt.bin>\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("fopen"); return 2; }
    fseek(f, 0, SEEK_END);
    long flen = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *orig = malloc(flen);
    if (fread(orig, 1, flen, f) != (size_t)flen) { fprintf(stderr, "short read\n"); return 2; }
    fclose(f);
    uint32_t len = (uint32_t)flen;
    uint64_t cap = ((uint64_t)len + DTPLANT_PAGE - 1) & ~(uint64_t)(DTPLANT_PAGE - 1);
    if (cap == len) cap += DTPLANT_PAGE;
    printf("blob %u bytes, test allocation %llu bytes (zero-filled page slack %llu)\n",
           len, (unsigned long long)cap, (unsigned long long)(cap - len));

    /* The fixture machine identity: a synthetic 16-byte seed authored
       for this test. Its derived payload is pinned byte-for-byte in
       the expectation below, so the derivation itself is under test. */
    static const uint8_t fixture_uuid[16] = {0x54, 0x45, 0x53, 0x54, 0x2d, 0x55, 0x55, 0x49,
                                             0x44, 0x2d, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31};

    /* No identity supplied: insert fails clean, buffer untouched. */
    {
        uint8_t *nb = calloc(1, cap);
        memcpy(nb, orig, len);
        uint8_t *nb0 = malloc(cap);
        memcpy(nb0, nb, cap);
        const char *nreason = NULL;
        uint32_t nnl = 0;
        int nr = dtplant_insert(nb, len, cap, &nnl, &nreason);
        CHECK(nr == 0, "seedless insert returned %d, want 0", nr);
        CHECK(nreason && !strcmp(nreason, "no machine identity supplied for the plant payload"),
              "seedless insert reason: %s", nreason ? nreason : "?");
        CHECK(!memcmp(nb, nb0, cap), "seedless failure modified the buffer");
        printf("seedless insert: PASS (%s)\n", nreason ? nreason : "?");
        free(nb); free(nb0);
    }
    dtplant_set_machine_uuid(fixture_uuid);

    const char *reason = NULL;
    DtplantInfo before;
    CHECK(dtplant_inspect(orig, len, &before, &reason), "pre-walk failed: %s", reason ? reason : "?");
    printf("pre-walk: nodes %u, props %u, options hdr %llu insert %llu nprops %u, target present %d\n",
           before.nodes, before.props, (unsigned long long)before.options_hdr,
           (unsigned long long)before.options_insert, before.options_nprops, before.target_present);
    CHECK(before.have_options, "input blob has no /options node");
    CHECK(!before.target_present, "input blob already carries the plant property");

    /* The expected 52-byte entry, built independently of the header. */
    uint8_t expect[52];
    memset(expect, 0, sizeof(expect));
    memcpy(expect, "bluetoothInternalControllerInfo", 31);
    expect[32] = 14;
    /* The fixture identity's derived payload: the format's zero
       prefix, then the derived internal address in HCI wire order. */
    static const uint8_t payload[14] = {0, 0, 0, 0, 0, 0, 0, 0, 0xA5, 0xE8, 0x1D, 0x98, 0x18, 0xF0};
    memcpy(expect + 36, payload, 14);

    uint8_t *buf = calloc(1, cap);
    memcpy(buf, orig, len);
    uint32_t new_len = 0;
    int r = dtplant_insert(buf, len, cap, &new_len, &reason);
    CHECK(r == 1, "insert returned %d (%s)", r, reason ? reason : "no reason");
    CHECK(new_len == len + 52, "new length %u != %u + 52", new_len, len);
    uint64_t at = before.options_insert;
    CHECK(!memcmp(buf + at, expect, 52), "entry bytes differ from the independent expectation");
    /* prefix up to the /options header is untouched except its count word */
    CHECK(!memcmp(buf, orig, before.options_hdr), "bytes before /options header changed");
    uint32_t np;
    memcpy(&np, buf + before.options_hdr, 4);
    CHECK(np == before.options_nprops + 1, "/options count %u != %u + 1", np, before.options_nprops);
    CHECK(!memcmp(buf + before.options_hdr + 4, orig + before.options_hdr + 4, at - before.options_hdr - 4),
          "bytes between /options header and insertion point changed");
    CHECK(!memcmp(buf + at + 52, orig + at, len - at), "shifted tail differs from the original tail");
    DtplantInfo after;
    reason = NULL;
    CHECK(dtplant_inspect(buf, new_len, &after, &reason), "post-walk failed: %s", reason ? reason : "?");
    printf("post-walk: nodes %u, props %u, options nprops %u, target present %d vlen %u\n",
           after.nodes, after.props, after.options_nprops, after.target_present, after.target_vlen);
    CHECK(after.nodes == before.nodes && after.props == before.props + 1, "node/property totals wrong");
    CHECK(after.target_present && after.target_vlen == 14 &&
          !memcmp(buf + after.target_val_off, payload, 14), "plant payload not found verbatim after insert");

    /* Second insert: already present, no-op. */
    uint8_t *snap = malloc(new_len);
    memcpy(snap, buf, new_len);
    uint32_t nl2 = 0;
    reason = NULL;
    r = dtplant_insert(buf, new_len, cap, &nl2, &reason);
    CHECK(r == 2, "second insert returned %d, want 2 (already present)", r);
    CHECK(!memcmp(buf, snap, new_len), "second insert modified the blob");
    free(snap);

    /* Truncated blob: clean failure, untouched. */
    uint8_t *t = calloc(1, cap);
    memcpy(t, orig, len - 10);
    uint8_t *t0 = malloc(len - 10);
    memcpy(t0, t, len - 10);
    reason = NULL;
    r = dtplant_insert(t, len - 10, cap, &nl2, &reason);
    CHECK(r == 0, "truncated insert returned %d, want 0", r);
    CHECK(!memcmp(t, t0, len - 10), "truncated failure modified the buffer");
    printf("truncated input: PASS (%s)\n", reason ? reason : "?");
    free(t); free(t0);

    /* Poisoned slack: capacity unprovable, untouched. */
    uint8_t *p = calloc(1, cap);
    memcpy(p, orig, len);
    p[len + 100] = 0xAA;
    uint8_t *p0 = malloc(cap);
    memcpy(p0, p, cap);
    reason = NULL;
    r = dtplant_insert(p, len, cap, &nl2, &reason);
    CHECK(r == 0, "poisoned-slack insert returned %d, want 0", r);
    CHECK(!memcmp(p, p0, cap), "poisoned-slack failure modified the buffer");
    printf("poisoned slack: PASS (%s)\n", reason ? reason : "?");
    free(p); free(p0);

    /* Short allocation (page end beyond bound): unprovable, untouched. */
    uint8_t *s = calloc(1, cap);
    memcpy(s, orig, len);
    uint8_t *s0 = malloc(cap);
    memcpy(s0, s, cap);
    reason = NULL;
    r = dtplant_insert(s, len, len + 10, &nl2, &reason);
    CHECK(r == 0, "short-allocation insert returned %d, want 0", r);
    CHECK(!memcmp(s, s0, cap), "short-allocation failure modified the buffer");
    printf("short allocation: PASS (%s)\n", reason ? reason : "?");
    free(s); free(s0);

    free(buf); free(orig);
    if (fails) { printf("test_dtplant: %d FAILURES\n", fails); return 1; }
    printf("test_dtplant: PASS (insert +52 into /options, byte-exact elsewhere, all failure paths clean)\n");
    return 0;
}
