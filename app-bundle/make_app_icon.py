#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the DSH.app icon set from the OFFICIAL DeepSeek Harness icon.

Source: https://github.com/deepseek-ai/deepseek-harness
        apps/desktop/resources/icon.png (1104x1104 RGBA, official desktop APP icon)

Why the official icon: dsh-Go (https://github.com/ccch1mneyyy/dsh-Go) ships its
OWN brand mark ("鱼尾与气泡", see its ASSETS.md), and its ASSETS.md explicitly
says the whale-tail artwork borrowed from DeepSeek is the official DeepSeek
icon and remains DeepSeek's trademark. This package IS DeepSeek Harness, so
using the official icon is both correct and expected.

`app-bundle/assets/AppIcon-1024.png` is the official artwork cropped to the
1024x1024 tile (the source has a 40/32px margin plus a drop shadow).  The
generator only decodes/resizes/encodes PNG with the stdlib, so output is
byte-identical on every host and no Pillow / ImageMagick is required.

Usage:
    python3 make_app_icon.py <outdir> [source.png]
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOURCE = os.path.join(HERE, "assets", "AppIcon-1024.png")

# All slots iOS 15/16 may ask for on iPhone + iPad.  Every entry is
# (filename, pixel size, scale, point size, idiom).
SPECS = [
    ("Icon20x20@2x.png", 40, 2, 20, "iphone"),
    ("Icon20x20@3x.png", 60, 3, 20, "iphone"),
    ("Icon29x29@2x.png", 58, 2, 29, "iphone"),
    ("Icon29x29@3x.png", 87, 3, 29, "iphone"),
    ("Icon40x40@2x.png", 80, 2, 40, "iphone"),
    ("Icon40x40@3x.png", 120, 3, 40, "iphone"),
    ("Icon60x60@2x.png", 120, 2, 60, "iphone"),
    ("Icon60x60@3x.png", 180, 3, 60, "iphone"),
    ("Icon76x76@2x.png", 152, 2, 76, "ipad"),
    ("Icon83.5x83.5@2x.png", 167, 2, 83.5, "ipad"),
    ("Icon1024.png", 1024, 1, 1024, "ios-marketing"),
]


def decode_png(path):
    """Decode an 8-bit RGBA/RGB PNG into (width, height, rows-of-RGBA)."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: " + path)
    pos, idat = 8, []
    width = height = None
    color_type = bit_depth = None
    palette = None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, comp, filt, interlace = struct.unpack(">IIBBBBB", chunk)
            if interlace != 0:
                raise ValueError("interlaced PNG not supported")
            if bit_depth != 8:
                raise ValueError("only 8-bit PNG supported")
        elif ctype == b"PLTE":
            palette = [tuple(chunk[i:i + 3]) for i in range(0, len(chunk), 3)]
        elif ctype == b"IDAT":
            idat.append(chunk)
        elif ctype == b"IEND":
            break
    raw = zlib.decompress(b"".join(idat))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    stride = width * channels
    rows, prev, p = [], bytearray(stride), 0

    def paeth(a, b, c):
        pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
        if pa <= pb and pa <= pc:
            return a
        return b if pb <= pc else c

    for _ in range(height):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 0:
            pass
        elif ft == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = prev[i]
                ul = prev[i - channels] if i >= channels else 0
                line[i] = (line[i] + paeth(left, up, ul)) & 0xFF
        else:
            raise ValueError("bad PNG filter %d" % ft)
        prev = line
        # Normalise every row to RGBA.
        if channels == 4:
            rows.append(bytes(line))
        else:
            out = bytearray(width * 4)
            for x in range(width):
                if channels == 3:
                    r, g, b = line[x * 3:x * 3 + 3]
                    a = 255
                elif channels == 1:
                    if color_type == 3:
                        r, g, b = palette[line[x]]
                    else:
                        r = g = b = line[x]
                    a = 255
                else:  # gray+alpha
                    r = g = b = line[x * 2]
                    a = line[x * 2 + 1]
                o = x * 4
                out[o:o + 4] = bytes((r, g, b, a))
            rows.append(bytes(out))
    return width, height, rows


def crop(rows, x0, y0, w, h):
    return [r[x0 * 4:(x0 + w) * 4] for r in rows[y0:y0 + h]]


def resize_area(rows, sw, sh, dw, dh):
    """Separable box/area resample.  Good for downscaling, exact for equal size."""
    if sw == dw and sh == dh:
        return rows
    # Horizontal pass: source rows -> dw wide (integer accumulation).
    tmp = []
    xmap = []
    for dx in range(dw):
        a = dx * sw / dw
        b = (dx + 1) * sw / dw
        xmap.append((a, b))
    for row in rows:
        out = bytearray(dw * 4)
        for dx, (a, b) in enumerate(xmap):
            ia, ib = int(a), int(b - 1e-9)
            if ib < ia:
                ib = ia
            r = g = bl = al = 0
            n = 0
            for sx in range(ia, min(ib + 1, sw)):
                o = sx * 4
                r += row[o]
                g += row[o + 1]
                bl += row[o + 2]
                al += row[o + 3]
                n += 1
            o = dx * 4
            out[o:o + 4] = bytes((r // n, g // n, bl // n, al // n))
        tmp.append(bytes(out))
    # Vertical pass.
    out_rows = []
    for dy in range(dh):
        a = dy * sh / dh
        b = (dy + 1) * sh / dh
        ia, ib = int(a), int(b - 1e-9)
        if ib < ia:
            ib = ia
        ys = range(ia, min(ib + 1, sh))
        n = len(ys)
        line = bytearray(dw * 4)
        for x in range(dw):
            r = g = bl = al = 0
            for sy in ys:
                row = tmp[sy]
                o = x * 4
                r += row[o]
                g += row[o + 1]
                bl += row[o + 2]
                al += row[o + 3]
            o = x * 4
            line[o:o + 4] = bytes((r // n, g // n, bl // n, al // n))
        out_rows.append(bytes(line))
    return out_rows


def encode_png(width, height, rows):
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw += row

    def chunk(typ, payload):
        c = struct.pack(">I", len(payload)) + typ + payload
        return c + struct.pack(">I", zlib.crc32(typ + payload) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    src = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_SOURCE
    os.makedirs(outdir, exist_ok=True)
    sw, sh, rows = decode_png(src)
    if (sw, sh) != (1024, 1024):
        raise SystemExit("expected 1024x1024 official tile, got %dx%d" % (sw, sh))
    cache = {}
    for name, size, _scale, _pt, _idiom in SPECS:
        if size not in cache:
            cache[size] = resize_area(rows, sw, sh, size, size)
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(encode_png(size, size, cache[size]))
        print("  %-26s %dx%d" % (name, size, size))


if __name__ == "__main__":
    main()
