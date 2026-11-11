#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 DSH.app 图标（纯几何绘制，不依赖任何字体文件 → 输出字节级确定）。

用户明确说过"太丑了太丑了"，所以这里走极简路线：
深墨蓝圆角方底 + 一个白色终端提示符 ">_"（两笔多边形）+ 左下角一个
小小的强调色圆点。没有渐变、没有阴影、没有文字渲染。
"""
import struct, sys, os

# --- 极简 PNG 编码器（zlib + 手写 chunk，避免 Pillow 版本差异影响可复现）---
import zlib


def png(width, height, pixels):
    """pixels: list of rows, each row = list of (r,g,b,a). RGBA8."""
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter type 0
        for (r, g, b, a) in row:
            raw += bytes((r, g, b, a))

    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


BG = (17, 24, 39, 255)       # #111827 深墨蓝
BG_EDGE = (31, 41, 55, 255)  # #1f2937 描边
FG = (249, 250, 251, 255)    # #f9fafb 近白
ACCENT = (56, 189, 248, 255) # #38bdf8 强调蓝


def inside_round_rect(x, y, w, h, r):
    """点是否落在圆角矩形内（含边）。"""
    if x < 0 or y < 0 or x >= w or y >= h:
        return False
    # 四角圆判定
    cx = min(x, w - 1 - x)
    cy = min(y, h - 1 - y)
    if cx < r and cy < r:
        dx, dy = r - cx, r - cy
        return dx * dx + dy * dy <= r * r
    return True


def render(S):
    """渲染 S x S 图标。"""
    px = [[(0, 0, 0, 0) for _ in range(S)] for _ in range(S)]
    r = int(S * 0.22)  # iOS 圆角比例
    # 1) 圆角方底（先铺边色，再铺内色留出 1px 描边感）
    for y in range(S):
        for x in range(S):
            if inside_round_rect(x, y, S, S, r):
                px[y][x] = BG
    # 2) ">" 提示符：两条平行四边形笔画，占中间偏左
    #    坐标按 S 归一化，保证各尺寸一致
    def poly(points, color):
        # 逐像素点在多边形内判定（图形很小，直接扫描整幅即可）
        minx = min(p[0] for p in points); maxx = max(p[0] for p in points)
        miny = min(p[1] for p in points); maxy = max(p[1] for p in points)
        for yy in range(max(0, int(miny)), min(S, int(maxy) + 2)):
            for xx in range(max(0, int(minx)), min(S, int(maxx) + 2)):
                # 射线法
                inside = False
                n = len(points)
                for i in range(n):
                    x1, y1 = points[i]
                    x2, y2 = points[(i + 1) % n]
                    if (y1 > yy) != (y2 > yy):
                        xin = x1 + (yy - y1) * (x2 - x1) / (y2 - y1)
                        if xx <= xin:
                            inside = not inside
                if inside and inside_round_rect(xx, yy, S, S, r):
                    px[yy][xx] = color

    A = S * 0.26; B = S * 0.44; T = S * 0.30; M = S * 0.37; D = S * 0.47
    th = max(2.0, S * 0.062)  # 笔画厚度
    # ">" 上斜
    poly([(A, T), (A + th, T - th * 0.15), (B + th * 0.4, M - th * 0.5),
          (B, M + th * 0.5)], FG)
    # ">" 下斜
    poly([(A, D - th * 0.5), (A + th, D + th * 0.35), (B + th * 0.4, M + th * 0.5),
          (B, M - th * 0.5)], FG)
    # 3) "_" 光标：一条横条
    x0 = int(S * 0.53); x1 = int(S * 0.74)
    y0 = int(S * 0.66); y1 = int(y0 + max(2.0, S * 0.062))
    for yy in range(y0, min(S, y1)):
        for xx in range(x0, min(S, x1)):
            if inside_round_rect(xx, yy, S, S, r):
                px[yy][xx] = FG
    # 4) 左下角强调圆点
    cx, cy, rad = S * 0.245, S * 0.735, S * 0.045
    for yy in range(int(cy - rad - 1), int(cy + rad + 2)):
        for xx in range(int(cx - rad - 1), int(cx + rad + 2)):
            if 0 <= xx < S and 0 <= yy < S and (xx - cx) ** 2 + (yy - cy) ** 2 <= rad * rad:
                if inside_round_rect(xx, yy, S, S, r):
                    px[yy][xx] = ACCENT
    return png(S, S, px)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)
    # iOS 需要的图标尺寸（2x/3x 的像素边长）
    specs = {
        "Icon60x60@2x.png": 120,
        "Icon60x60@3x.png": 180,
        "Icon76x76@2x.png": 152,
        "Icon83.5x83.5@2x.png": 167,
        "Icon1024.png": 1024,
    }
    for name, size in specs.items():
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(render(size))
        print("  %-26s %dx%d" % (name, size, size))


if __name__ == "__main__":
    main()
