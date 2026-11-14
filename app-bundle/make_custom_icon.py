#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate an ORIGINAL DSH app icon (no DeepSeek trademark artwork).

Design: a light "paper" tile (matching the official app's light icon family)
with a bold dark-navy letter D and a cyan terminal cursor in its counter.
The D is drawn from signed-distance shapes, anti-aliased per pixel, so it is
crisp at 1024 and at 60 px.  Pure stdlib, deterministic output.

Usage:
    python3 make_custom_icon.py [out.png]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from make_app_icon import encode_png  # noqa: E402

SIZE = 1024

# palette
NAVY = (15, 23, 42)
CYAN = (56, 189, 248)
SHADOW = (15, 23, 42)


def rounded_box_sdf(px, py, cx, cy, hx, hy, r):
    qx = abs(px - cx) - hx + r
    qy = abs(py - cy) - hy + r
    ax = max(qx, 0.0)
    ay = max(qy, 0.0)
    return math.sqrt(ax * ax + ay * ay) + min(max(qx, qy), 0.0) - r


def half_annulus_sdf(px, py, cx, cy, r_out, r_in):
    # annulus, then cut at x = cx (keep x >= cx).  Negative outside/inside,
    # positive only in the ring.
    d = abs(math.hypot(px - cx, py - cy) - (r_out + r_in) * 0.5) - (r_out - r_in) * 0.5
    cut = cx - px  # >0 on the left of cx
    return max(d, cut)


def d_sdf(px, py):
    # vertical stem
    d1 = rounded_box_sdf(px, py, 361.0, 512.0, 60.0, 302.0, 48.0)
    # bowl: right half ring, centre (421, 512)
    d2 = half_annulus_sdf(px, py, 421.0, 512.0, 302.0, 178.0)
    return min(d1, d2)


def mix(a, b, t):
    return a + (b - a) * t


def render():
    rows = []
    # precompute background rows
    for y in range(SIZE):
        row = bytearray()
        for x in range(SIZE):
            # light diagonal gradient + soft top-left glow
            t = (x + y) / (2.0 * SIZE)
            r = mix(250.0, 226.0, t)
            g = mix(252.0, 234.0, t)
            b = mix(255.0, 247.0, t)
            gx, gy = x - 300.0, y - 220.0
            glow = max(0.0, 1.0 - (gx * gx + gy * gy) / (620.0 * 620.0))
            r += 5.0 * glow
            g += 4.0 * glow
            b += 2.0 * glow

            d = d_sdf(x + 0.5, y + 0.5)
            # anti-aliased coverage of the D
            cov = min(1.0, max(0.0, 0.5 - d))
            if cov > 0.0:
                r = mix(r, NAVY[0], cov)
                g = mix(g, NAVY[1], cov)
                b = mix(b, NAVY[2], cov)
            # soft shadow just outside the D (offset down)
            ds = d_sdf(x + 0.5, y + 0.5 - 18.0)
            if ds > 0.0:
                sa = 0.10 * max(0.0, 1.0 - ds / 26.0)
                if sa > 0.002:
                    r = mix(r, SHADOW[0], sa)
                    g = mix(g, SHADOW[1], sa)
                    b = mix(b, SHADOW[2], sa)

            # cyan cursor in the counter
            dc = rounded_box_sdf(x + 0.5, y + 0.5, 512.0, 570.0, 62.0, 22.0, 18.0)
            cc = min(1.0, max(0.0, 0.5 - dc))
            if cc > 0.0:
                r = mix(r, CYAN[0], cc)
                g = mix(g, CYAN[1], cc)
                b = mix(b, CYAN[2], cc)

            row += bytes((min(255, max(0, int(r + 0.5))), min(255, max(0, int(g + 0.5))), min(255, max(0, int(b + 0.5))), 255))
        rows.append(bytes(row))
    return rows


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "assets", "AppIcon-1024.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    rows = render()
    open(out, "wb").write(encode_png(SIZE, SIZE, rows))
    print("wrote", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
