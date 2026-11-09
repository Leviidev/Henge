#!/usr/bin/env python3
"""Build the synthetic ADT fixture for tests/test_dtplant.c.

Format (from host/dtplant.h, the exact code the test exercises):
  node     := u32 nProperties, u32 nChildren, properties, children
  property := char name[32] (NUL-padded), u32 length, value bytes padded
              up to a 4-byte multiple; the length word's TOP BIT is a flag
              and the value size is length & 0x7fffffff.

The fixture is a minimal but structurally faithful tree: a root node
carrying a flagged syscfg-style template property (exercising the flag
mask, as syscfg-style properties do), an /options child with
two properties (name, AAPL,phandle),
and a sibling node after /options so the insert must shift a real tail.
Every byte of the fixture is generated from the format definition above.
"""
import struct, sys

def prop(name, value, flag=False):
    nb = name.encode()
    assert 0 < len(nb) < 32
    field = nb + b"\x00" * (32 - len(nb))
    length = len(value) | (0x80000000 if flag else 0)
    pad = (-len(value)) % 4
    return field + struct.pack("<I", length) + value + b"\x00" * pad

def node(props, children):
    out = struct.pack("<II", len(props), len(children))
    for p in props:
        out += p
    for c in children:
        out += c
    return out

options = node([
    prop("name", b"options\x00"),
    prop("AAPL,phandle", struct.pack("<I", 0x11)),
], [])
chosen = node([
    prop("name", b"chosen\x00"),
    prop("boot-args", b"synthetic\x00"),
], [])
root = node([
    prop("name", b"device-tree\x00"),
    prop("serial-number", b"syscfg/SrNm/0x20", flag=True),
    prop("model", b"Synthetic ADT fixture\x00"),
], [options, chosen])

out = sys.argv[1] if len(sys.argv) > 1 else "tests/fixtures/adt-synthetic.bin"
with open(out, "wb") as fh:
    fh.write(root)
print("wrote %s: %d bytes" % (out, len(root)))
