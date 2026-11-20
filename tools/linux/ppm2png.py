#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""ppm2png.py IN.ppm OUT.png: a binary PPM (P6, what hengelinux's HV_FB_DUMP writes) as a PNG, with the
standard library only. Also prints how much of the screen is not black, so a log shows whether anything drew."""
import struct, sys, zlib

def main(src, dst):
    data = open(src, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace(): pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace(): end += 1
        fields.append(data[pos:end]); pos = end
    assert fields[0] == b"P6", "not a binary PPM"
    w, h = int(fields[1]), int(fields[2])
    pix = data[pos + 1:pos + 1 + w * h * 3]
    rows = b"".join(b"\x00" + pix[y * w * 3:(y + 1) * w * 3] for y in range(h))
    def chunk(kind, body): return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b"")
    open(dst, "wb").write(png)
    lit = sum(1 for i in range(0, len(pix), 3 * 7) if pix[i] | pix[i + 1] | pix[i + 2])
    print(f"screen {w}x{h}: {100.0 * lit / max(1, len(pix) // (3 * 7)):.0f}% of it not black -> {dst}")
    # For a log that cannot show images: the main colours, and a thumbnail in characters by brightness.
    counts = {}
    for i in range(0, len(pix), 3 * 13):
        c = pix[i:i + 3]
        counts[c] = counts.get(c, 0) + 1
    total = sum(counts.values())
    print("colours: " + ", ".join(f"#{c.hex()} {100.0 * n / total:.0f}%" for c, n in sorted(counts.items(), key=lambda kv: -kv[1])[:6])
          + f" ({len(counts)} sampled)")
    ramp, cols, lines = " .:-=+*#%@", 80, 24
    for ty in range(lines):
        row = ""
        for tx in range(cols):
            x, y = tx * w // cols + w // cols // 2, ty * h // lines + h // lines // 2
            o = (y * w + x) * 3
            lum = (pix[o] * 3 + pix[o + 1] * 6 + pix[o + 2]) // 10
            row += ramp[min(len(ramp) - 1, lum * len(ramp) // 256)]
        print("|" + row + "|")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
