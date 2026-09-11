#!/usr/bin/env python3
"""Generate YatraWise launcher icon PNGs (no external deps)."""
import zlib, struct, os

TOP = (0x0B, 0x39, 0x54)      # deep navy-teal
BOTTOM = (0x0E, 0x7C, 0x7B)   # teal

def bg(t):
    return tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))

def in_pin(x, y):
    """Teardrop map pin: circle center (54,42) r=17, tip at (54,82)."""
    dx, dy = x - 54.0, y - 42.0
    if dx * dx + dy * dy <= 17.0 * 17.0:
        return True
    if 42.0 < y <= 82.0:
        w = 17.0 * ((1.0 - (y - 42.0) / 40.0) ** 0.92)
        return abs(dx) <= w
    return False

def in_hole(x, y):
    dx, dy = x - 54.0, y - 42.0
    return dx * dx + dy * dy <= 7.0 * 7.0

def pixel(x, y):
    t = y / 108.0
    b = bg(t)
    if in_hole(x + 0.5, y + 0.5):
        pass  # hole keeps background color
    elif in_pin(x + 0.5, y + 0.5):
        return (255, 255, 255, 255)
    return (b[0], b[1], b[2], 255)

def render(size):
    scale = 2  # supersample
    big = size * scale
    rows = []
    for sy in range(size):
        row = bytearray()
        for sx in range(size):
            rs = gs = bs = 0
            for j in range(scale):
                for i in range(scale):
                    p = pixel((sx * scale + i) * 108.0 / big, (sy * scale + j) * 108.0 / big)
                    rs += p[0]; gs += p[1]; bs += p[2]
            n = scale * scale
            row += bytes((rs // n, gs // n, bs // n, 255))
        rows.append(bytes(row))
    return rows

def write_png(path, size):
    raw = b"".join(b"\x00" + r for r in render(size))
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    data = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    print(path, len(data), "bytes")

base = "android/app/src/main/res"
for dpi, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
    write_png(f"{base}/mipmap-{dpi}/ic_launcher.png", size)
    write_png(f"{base}/mipmap-{dpi}/ic_launcher_round.png", size)
