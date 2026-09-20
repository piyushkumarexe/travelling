#!/usr/bin/env python3
"""Install the YatraWise logo everywhere it belongs — no Pillow, no network.

Usage:
    python3 tools/install_logo.py <path-to-logo.png>

What it does:
  1. assets/images/yatrawise-logo.png   (in-app brand mark; AppLogo prefers
     this file, so the login screen picks it up with zero code changes)
  2. android .../mipmap-*/ic_launcher.png, ic_launcher_round.png and
     ic_launcher_foreground.png at the densities Flutter/Android expect
     (48/72/96/144/192 legacy, 108/162/216/324/432 adaptive foreground with
     the artwork inside the 66/108 safe zone).

Only a *decode + resize + encode* pipeline is implemented here (pure stdlib),
so the source must be a non-interlaced 8-bit PNG (RGB / RGBA / gray / palette)
— which is what a phone or any editor exports. Everything is derived from the
same square-cropped artwork so the store listing, launcher and login screen
cannot drift apart.
"""
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSET = os.path.join(ROOT, 'assets', 'images', 'yatrawise-logo.png')
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')

# (density dir, legacy icon size, adaptive foreground size)
DENSITIES = [
    ('mipmap-mdpi', 48, 108),
    ('mipmap-hdpi', 72, 162),
    ('mipmap-xhdpi', 96, 216),
    ('mipmap-xxhdpi', 144, 324),
    ('mipmap-xxxhdpi', 192, 432),
]
ASSET_SIZE = 1024
BRAND_CREAM = '#FEFAF1'   # the logo's own background colour
PREP_SIZE = 512   # working size for the icon sweep (quality vs. pure-python speed)


# ---------------------------------------------------------------- PNG decode
def png_read(path):
    """Return (width, height, rows) with rows a list of RGBA bytearrays."""
    with open(path, 'rb') as fh:
        data = fh.read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit('%s is not a PNG file' % path)
    pos, idat, chunks = 8, b'', {}
    while pos < len(data):
        (length,) = struct.unpack('>I', data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if ctype == b'IHDR':
            (w, h, depth, color, comp, filt, interlace) = struct.unpack(
                '>IIBBBBB', body)
        elif ctype == b'IDAT':
            idat += body
        else:
            chunks[ctype] = body
        pos += 12 + length
    if depth != 8:
        raise SystemExit('only 8-bit PNGs are supported (got depth %d)' % depth)
    if interlace != 0:
        raise SystemExit('interlaced (progressive) PNGs are not supported — '
                         're-export the file without interlacing')
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color)
    if channels is None:
        raise SystemExit('unsupported PNG colour type %d' % color)
    raw = zlib.decompress(idat)
    stride = w * channels
    prev = bytearray(stride)
    rows, o = [], 0
    for _ in range(h):
        ftype = raw[o]
        line = bytearray(raw[o + 1:o + 1 + stride])
        o += 1 + stride
        if ftype == 1:                      # Sub
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + left) & 0xFF
        elif ftype == 2:                    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:                    # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:                    # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p, pa, pb, pc = a + b - c, abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else
                                      b if pb <= pc else c)) & 0xFF
        elif ftype != 0:
            raise SystemExit('unknown PNG filter type %d' % ftype)
        rows.append(line)
        prev = line
    if color == 3:                          # palette
        pal = chunks[b'PLTE']
        trns = chunks.get(b'tRNS', b'')
        out = []
        for line in rows:
            r = bytearray()
            for idx in line:
                r += pal[idx * 3:idx * 3 + 3]
                r += bytes([trns[idx] if idx < len(trns) else 255])
            out.append(r)
        rows = out
    elif channels == 1:                     # gray
        rows = [bytes(v for px in line for v in (px, px, px, 255))
                for line in rows]
    elif channels == 3:                     # RGB → RGBA
        rows = [_rgb_to_rgba(bytes(line), w) for line in rows]
    elif channels == 2:                     # gray + alpha
        rows = [bytes(v for i in range(0, len(line), 2)
                      for v in (line[i], line[i], line[i], line[i + 1]))
                for line in rows]
    return w, h, [bytearray(r) for r in rows]


def _rgb_to_rgba(line, w):
    out = bytearray(w * 4)
    for i in range(w):
        out[i * 4:i * 4 + 3] = line[i * 3:i * 3 + 3]
        out[i * 4 + 3] = 255
    return out


# ---------------------------------------------------------------- PNG encode
def png_write(path, w, h, rows):
    raw = bytearray()
    prev = bytearray(w * 4)
    for line in rows:
        raw.append(2)                       # Up filter: great for flat art
        for i in range(w * 4):
            raw.append((line[i] - prev[i]) & 0xFF)
        prev = line
    comp = zlib.compress(bytes(raw), 9)

    def chunk(tag, body):
        return (struct.pack('>I', len(body)) + tag + body +
                struct.pack('>I', zlib.crc32(tag + body) & 0xFFFFFFFF))

    with open(path, 'wb') as fh:
        fh.write(b'\x89PNG\r\n\x1a\n')
        fh.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        fh.write(chunk(b'IDAT', comp))
        fh.write(chunk(b'IEND', b''))


# ------------------------------------------------------------------ geometry
def square_crop(w, h, rows):
    side = min(w, h)
    x0, y0 = (w - side) // 2, (h - side) // 2
    return side, side, [rows[y0 + y][x0 * 4:(x0 + side) * 4]
                        for y in range(y0, y0 + side)]


def _axis_weights(src, dst):
    """For each output index: the list of (source index, coverage weight).

    Covers the whole source range, so downscaling averages every input pixel
    (area sampling) instead of picking one and aliasing the artwork away.
    """
    scale = src / float(dst)
    out = []
    for i in range(dst):
        lo, hi = i * scale, (i + 1) * scale
        a, b = int(lo), min(src - 1, int(hi - 1e-9))
        if b < a:
            a, b = min(src - 1, a), min(src - 1, a)
        span = []
        for j in range(a, b + 1):
            cover = min(hi, j + 1.0) - max(lo, float(j))
            if cover > 0:
                span.append((j, cover))
        total = sum(c for _, c in span) or 1.0
        out.append([(j, c / total) for j, c in span])
    return out


def resize(w, h, rows, size, scale=1.0, pad_transparent=False):
    """Resample to a size x size square image (premultiplied alpha).

    With pad_transparent the artwork is first scaled to size*scale and then
    centred on a transparent canvas of `size` — how an adaptive launcher
    foreground has to keep the OS safe zone around the art.
    """
    side = max(1, min(size, int(round(size * scale))))
    off = (size - side) // 2 if pad_transparent else 0
    src = [bytes(r) for r in rows]
    xs = _axis_weights(w, side)
    ys = _axis_weights(h, side)
    canvas = [bytearray(size * 4) for _ in range(size)]

    def horiz(y):
        row = src[y]
        out = bytearray(side * 4)
        for x, span in enumerate(xs):
            if len(span) == 1 and span[0][1] >= 0.9999:  # exact copy
                j = span[0][0] * 4
                out[x * 4:x * 4 + 4] = row[j:j + 4]
                continue
            acc = [0.0] * 4
            for j, cw in span:
                o = j * 4
                a = row[o + 3] / 255.0
                for c in range(3):
                    acc[c] += row[o + c] * a * cw
                acc[3] += a * cw
            alpha = acc[3]
            o = x * 4
            for c in range(3):
                out[o + c] = min(255, int(round(acc[c] / alpha))) if alpha > 0.004 else 0
            out[o + 3] = min(255, int(round(alpha * 255)))
        return out

    for y, yspan in enumerate(ys):
        # Only the handful of source rows this output row touches.
        cache = {j: horiz(j) for j, _ in yspan}
        if len(yspan) == 1 and yspan[0][1] >= 0.9999:
            line = cache[yspan[0][0]]
        else:
            acc = [0.0] * (side * 4)
            for j, cw in yspan:
                row = cache[j]
                for i in range(side * 4):
                    acc[i] += row[i] * cw
            line = bytearray(int(round(v)) for v in acc)
        canvas[y + off][off * 4:off * 4 + side * 4] = line
    return canvas


def circle_mask(size, rows):
    cx = cy = (size - 1) / 2.0
    r = size / 2.0
    edge = max(1.0, size / 96.0)             # ~1px AA at mdpi
    for y in range(size):
        line = rows[y]
        for x in range(size):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if d <= r - edge:
                continue
            if d >= r + edge:
                line[x * 4 + 3] = 0
            else:
                t = (r + edge - d) / (2 * edge)
                line[x * 4 + 3] = int(line[x * 4 + 3] * max(0.0, min(1.0, t)))
    return rows


def pad_to_square(w, h, rows, fill=(0, 0, 0, 0)):
    """Letterbox a non-square image onto a transparent (or filled) square.

    Used for the in-app asset: the brand artwork keeps its own proportions
    instead of being cropped, and the widget that shows it stays a square.
    """
    side = max(w, h)
    ox, oy = (side - w) // 2, (side - h) // 2
    blank = bytes(fill) * side
    out = [bytearray(blank) for _ in range(side)]
    for y in range(h):
        src = rows[y]
        dst = out[y + oy]
        dst[ox * 4:ox * 4 + w * 4] = src[:w * 4]
    return side, side, out


def flatten_onto(rows, rgb):
    """Composite RGBA over an opaque colour.

    Android 8.0 and older read `ic_launcher.png` as a plain bitmap: transparent
    pixels there render as a black slab behind the logo. The adaptive
    foreground (API 26+) keeps its transparency and lets the OS paint the
    background layer, so only the legacy icons are flattened.
    """
    r, g, b = rgb
    for line in rows:
        for i in range(0, len(line), 4):
            a = line[i + 3]
            if a == 255:
                continue
            na = 255
            inv = 255 - a
            line[i] = (line[i] * a + r * inv) // 255
            line[i + 1] = (line[i + 1] * a + g * inv) // 255
            line[i + 2] = (line[i + 2] * a + b * inv) // 255
            line[i + 3] = na
    return rows


def _hex_rgb(value):
    v = value.lstrip('#')
    if len(v) == 3:
        v = ''.join(c * 2 for c in v)
    if len(v) != 6:
        raise SystemExit('bad colour %r (expected #RRGGBB)' % value)
    return tuple(int(v[i:i + 2], 16) for i in (0, 2, 4))


def main():
    import argparse

    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('source', nargs='?', help='non-interlaced 8-bit PNG logo')
    ap.add_argument('--fit', choices=('crop', 'pad'), default='crop',
                    help="crop = centre square crop (icons); "
                         "pad = keep proportions on a square canvas (asset)")
    ap.add_argument('--only', choices=('all', 'asset', 'icons'), default='all')
    ap.add_argument('--asset-size', type=int, default=ASSET_SIZE,
                    help='edge length of assets/images/yatrawise-logo.png')
    ap.add_argument('--asset', default=ASSET, help='override the asset path')
    ap.add_argument('--flatten', default=BRAND_CREAM,
                    help='opaque background for the legacy launcher icons')
    args = ap.parse_args()
    if not args.source or not os.path.exists(args.source):
        ap.error('give me a PNG file that exists: install_logo.py <logo.png>')

    w, h, rows = png_read(args.source)
    print('source %dx%d, fit=%s' % (w, h, args.fit))
    if args.fit == 'crop':
        w, h, rows = square_crop(w, h, rows)
    else:
        w, h, rows = pad_to_square(w, h, rows)
    if args.only in ('all', 'asset'):
        # The asset keeps the source's own detail (it is drawn at up to 168 dp
        # on a 3x phone, so 512+ is plenty; never blow a small logo up).
        size = min(args.asset_size, w)
        os.makedirs(os.path.dirname(args.asset), exist_ok=True)
        png_write(args.asset, size, size, resize(w, h, rows, size))
        print('wrote %s (%dx%d)' % (os.path.relpath(args.asset, ROOT),
                                    size, size))

    if args.only in ('all', 'icons'):
        if w > PREP_SIZE:             # one bounded pass feeds all five densities
            rows = resize(w, h, rows, PREP_SIZE)
            w = h = PREP_SIZE
        bg = _hex_rgb(args.flatten)
        for d, legacy, adaptive in DENSITIES:
            base = os.path.join(RES, d)
            if not os.path.isdir(base):
                continue
            icon = resize(w, h, rows, legacy)
            # Legacy icons are opaque bitmaps; the round one gets the circle.
            png_write(os.path.join(base, 'ic_launcher.png'), legacy, legacy,
                      flatten_onto([bytearray(r) for r in icon], bg))
            rounded = [bytearray(r) for r in icon]
            circle_mask(legacy, rounded)
            png_write(os.path.join(base, 'ic_launcher_round.png'),
                      legacy, legacy, flatten_onto(rounded, bg))
            # Adaptive foreground (API 26+): transparency kept, art inside the
            # 66/108 safe zone so the OS can mask it any shape it likes.
            png_write(os.path.join(base, 'ic_launcher_foreground.png'),
                      adaptive, adaptive,
                      resize(w, h, rows, adaptive, scale=66.0 / 108.0,
                             pad_transparent=True))
            print('wrote %s  %dpx icon + %dpx foreground'
                  % (d, legacy, adaptive))
    print('\nDone. Rebuild the APK to ship the new brand mark.')


if __name__ == '__main__':
    main()
