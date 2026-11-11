#!/usr/bin/env python3
import math
import os
import struct
import zlib

SIZE = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "App", "AppIcon.png")


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(int(lerp(a, b, t)) for a, b in zip(c1, c2))


def rounded_rect(px, py, w, h, r):
    x = min(max(px, 0), w)
    y = min(max(py, 0), h)
    dx = abs(x - min(max(x, r), w - r))
    dy = abs(y - min(max(y, r), h - r))
    if r <= x <= w - r or r <= y <= h - r:
        inside = 0 <= x <= w and 0 <= y <= h
        return 1.0 if inside else 0.0
    dist = math.hypot(x - (r if x < r else w - r), y - (r if y < r else h - r))
    return 1.0 if dist <= r else max(0.0, 1.0 - (dist - r))


def bubble(px, py, cx, cy, w, h):
    lx = px - (cx - w / 2)
    ly = py - (cy - h / 2)
    return rounded_rect(lx, ly, w, h, 120)


def tail(px, py):
    # small triangle-ish blob at bottom-left of the bubble
    ax, ay = 310, 690
    bx, by = 250, 860
    cx, cy = 430, 720
    v0x, v0y = cx - ax, cy - ay
    v1x, v1y = bx - ax, by - ay
    v2x, v2y = px - ax, py - ay
    den = v0x * v1y - v1x * v0y
    if den == 0:
        return 0.0
    a = (v2x * v1y - v1x * v2y) / den
    b = (v0x * v2y - v2x * v0y) / den
    c = 1 - a - b
    if a >= 0 and b >= 0 and c >= 0:
        return 1.0
    return 0.0


def dot(px, py, cx, cy, r):
    d = math.hypot(px - cx, py - cy)
    if d <= r - 2:
        return 1.0
    if d >= r + 2:
        return 0.0
    return max(0.0, 1.0 - (d - (r - 2)) / 4)


def generate():
    bg1 = (18, 24, 38, 255)
    bg2 = (28, 38, 58, 255)
    bubble_c = (62, 196, 74, 255)
    bubble_d = (38, 140, 52, 255)
    accent = (232, 236, 90, 255)
    rows = []
    for y in range(SIZE):
        row = []
        gy = y / (SIZE - 1)
        for x in range(SIZE):
            gx = x / (SIZE - 1)
            base = mix(bg1, bg2, (gx + gy) / 2)
            # squircle mask
            nx = (x + 0.5) / SIZE * 2 - 1
            ny = (y + 0.5) / SIZE * 2 - 1
            squircle = (abs(nx) ** 4 + abs(ny) ** 4) ** 0.25
            alpha = 1.0 if squircle < 0.92 else max(0.0, 1.0 - (squircle - 0.92) / 0.06)
            b = bubble(x, y, 530, 470, 620, 470)
            t = tail(x, y)
            d = dot(x, y, 780, 250, 70)
            col = base
            cover = max(b, t)
            if cover > 0:
                shade = mix(bubble_c, bubble_d, (y / SIZE) * 0.7)
                col = mix(col, shade, cover)
            if d > 0:
                col = mix(col, accent, d)
            row.extend([
                int(col[0] * alpha + 0),
                int(col[1] * alpha + 0),
                int(col[2] * alpha + 0),
                int(255 * alpha),
            ])
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    raw = b"".join(b"\x00" + row for row in rows)
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(png)


def write_icns(png_path, icns_path):
    with open(png_path, "rb") as handle:
        png = handle.read()
    # ic10 is 1024x1024 PNG inside ICNS
    entry_len = 8 + len(png)
    total = 8 + entry_len
    with open(icns_path, "wb") as handle:
        handle.write(b"icns")
        handle.write(struct.pack(">I", total))
        handle.write(b"ic10")
        handle.write(struct.pack(">I", entry_len))
        handle.write(png)


if __name__ == "__main__":
    png_path = os.path.abspath(OUT)
    write_png(png_path, generate())
    icns_path = os.path.splitext(png_path)[0] + ".icns"
    write_icns(png_path, icns_path)
    print("wrote", png_path)
    print("wrote", icns_path)
