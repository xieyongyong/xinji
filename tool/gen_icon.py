# -*- coding: utf-8 -*-
"""生成「薪迹」应用图标：红底 + Twitter 的 X 字形。

为什么用纯 Python 画而不是调图像库：
  这台机器没装 Pillow，装它又要走代理。图标是纯矢量图形，
  自己写「路径光栅化 + PNG 编码」（zlib 是标准库）反而最可控、零依赖。

设计说明：
  - 底色：深红竖向渐变（保留上一版背景，用户认可的）
  - 主体：**真正的 X 标志轮廓**，不是两笔圆头粗线拼的叉
    —— 用户明确说"背景可以，但 X 不喜欢，沿用 Twitter 的 X 图标"
  - 字形用官方 SVG 路径（1200×1227 视图框）+ 奇偶填充规则，
    内圈是挖空的反向子路径，画出来才是那个有棱角的 X
"""
import math
import os
import re
import struct
import zlib

# ---------------------------------------------------------------- PNG 编码


def write_png(path, w, h, rgba):
    raw = b''.join(b'\x00' + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))
    comp = zlib.compress(raw, 9)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', comp)
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


# ---------------------------------------------------------------- 背景配色

BG_TOP = (211, 47, 47)
BG_BOTTOM = (142, 16, 16)
GLYPH = (255, 255, 255)


def _lerp(a, b, k):
    k = 0.0 if k < 0 else (1.0 if k > 1 else k)
    return tuple(a[i] + (b[i] - a[i]) * k for i in range(3))


# ---------------------------------------------------------------- SVG 路径

# X（原 Twitter）官方标志，viewBox 0 0 24 24
# 取自 simple-icons 的官方形状：外轮廓 + 一条细细的"挖空"带，
# 那条带就是 X 标志中间那条缝，去掉它就成了普通的手写叉。
X_PATH = (
    'M14.234 10.162 22.977 0h-2.072l-7.591 8.824L7.251 0H.258l9.168 13.343'
    'L.258 24H2.33l8.016-9.318L16.749 24h6.993'
    'zm-2.837 3.299-.929-1.329L3.076 1.56h3.182l5.965 8.532.929 1.329'
    ' 7.754 11.09h-3.182z'
)

VIEW_W, VIEW_H = 24.0, 24.0

_TOKEN = re.compile(r'[MLHVmlhvzZ]|-?\d*\.?\d+(?:[eE][-+]?\d+)?')


def parse_path(d):
    """支持 M/L/H/V/Z 及其相对写法（够用了），返回若干闭合多边形。"""
    toks = _TOKEN.findall(d)
    subs, cur = [], []
    x = y = 0.0
    sx = sy = 0.0
    cmd = None
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.isalpha():
            cmd = t
            i += 1
            if cmd in 'Zz':
                if len(cur) >= 3:
                    subs.append(cur)
                cur = []
                x, y = sx, sy
            continue
        rel = cmd.islower()
        c = cmd.upper()
        if c == 'M':
            nx, ny = float(toks[i]), float(toks[i + 1])
            i += 2
            if rel:
                nx, ny = x + nx, y + ny
            x, y = nx, ny
            sx, sy = x, y
            cur = [(x, y)]
            cmd = 'l' if rel else 'L'
        elif c == 'L':
            nx, ny = float(toks[i]), float(toks[i + 1])
            i += 2
            if rel:
                nx, ny = x + nx, y + ny
            x, y = nx, ny
            cur.append((x, y))
        elif c == 'H':
            nx = float(toks[i])
            i += 1
            x = x + nx if rel else nx
            cur.append((x, y))
        elif c == 'V':
            ny = float(toks[i])
            i += 1
            y = y + ny if rel else ny
            cur.append((x, y))
        else:
            i += 1
    if len(cur) >= 3:
        subs.append(cur)
    return subs


def build_edges(subpaths, ox, oy, scale):
    """把所有多边形边做成扫描线用的边表（已做坐标变换）。"""
    edges = []
    for poly in subpaths:
        pts = [(ox + px * scale, oy + py * scale) for px, py in poly]
        n = len(pts)
        for k in range(n):
            x0, y0 = pts[k]
            x1, y1 = pts[(k + 1) % n]
            if y0 == y1:
                continue
            edges.append((x0, y0, x1, y1))
    return edges


def rasterize(edges, size):
    """奇偶规则扫描线填充，返回 size×size 的 0/1 覆盖位图（逐行 bytearray）。"""
    rows = [bytearray(size) for _ in range(size)]
    for py in range(size):
        sy = py + 0.5
        xs = []
        for x0, y0, x1, y1 in edges:
            if (y0 <= sy < y1) or (y1 <= sy < y0):
                t = (sy - y0) / (y1 - y0)
                xs.append(x0 + (x1 - x0) * t)
        if not xs:
            continue
        xs.sort()
        row = rows[py]
        for k in range(0, len(xs) - 1, 2):
            a, b = xs[k], xs[k + 1]
            ia = int(math.ceil(a - 0.5))
            ib = int(math.floor(b - 0.5))
            if ia < 0:
                ia = 0
            if ib > size - 1:
                ib = size - 1
            for x in range(ia, ib + 1):
                row[x] = 1
    return rows


def coverage(mask, size, ss):
    """把 ss 倍超采样的位图降采样成 0..1 的覆盖率。"""
    n = ss * ss
    out = []
    for y in range(size):
        row = [0.0] * size
        for dy in range(ss):
            src = mask[y * ss + dy]
            base = 0
            for x in range(size):
                acc = 0
                for dx in range(ss):
                    acc += src[base + dx]
                base += ss
                row[x] += acc
        out.append([v / n for v in row])
    return out


def render(size, glyph_ratio=0.60, with_bg=True, ss=3):
    """渲染一张 size×size 的 RGBA 图标。"""
    big = size * ss

    # 字形缩放到画布中央（等比，按宽度算）
    gscale = (big * glyph_ratio) / VIEW_W
    drawn_w = VIEW_W * gscale
    drawn_h = VIEW_H * gscale
    ox = (big - drawn_w) / 2
    oy = (big - drawn_h) / 2

    subpaths = parse_path(X_PATH)

    # 纯白字形，不做投影/斜面 —— X 的标志是扁平的，
    # 加立体反而把它弄脏（上一版就是"红底立体 X"，用户不喜欢）
    main_mask = rasterize(build_edges(subpaths, ox, oy, gscale), big)

    buf = bytearray(big * big * 4)
    for py in range(big):
        fy = (py + 0.5) / big
        mrow = main_mask[py]
        for px in range(big):
            i = (py * big + px) * 4

            if with_bg:
                r, g, b = _lerp(BG_TOP, BG_BOTTOM, fy ** 0.85)
                # 顶部中央一点柔光，让红色不呆板
                halo = max(0.0, 1.0 - math.hypot(px / big - 0.5, fy - 0.30) / 0.62)
                halo = halo ** 2 * 0.26
                r += (255 - r) * halo * 0.40
                g += (255 - g) * halo * 0.26
                b += (255 - b) * halo * 0.26
                a = 255.0
            else:
                r = g = b = 0.0
                a = 0.0

            # 字形
            if mrow[px]:
                r, g, b = GLYPH
                a = 255.0

            buf[i] = int(r)
            buf[i + 1] = int(g)
            buf[i + 2] = int(b)
            buf[i + 3] = int(a if a >= 255 else a)

    # 盒式降采样抗锯齿
    out = bytearray(size * size * 4)
    n = ss * ss
    for y in range(size):
        for x in range(size):
            rs = gs = bs = as_ = 0
            for dy in range(ss):
                base = ((y * ss + dy) * big + x * ss) * 4
                for dx in range(ss):
                    j = base + dx * 4
                    rs += buf[j]
                    gs += buf[j + 1]
                    bs += buf[j + 2]
                    as_ += buf[j + 3]
            o = (y * size + x) * 4
            out[o] = rs // n
            out[o + 1] = gs // n
            out[o + 2] = bs // n
            out[o + 3] = as_ // n
    return bytes(out)


# ---------------------------------------------------------------- 输出

RES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'android', 'app', 'src', 'main', 'res')

DENSITIES = {
    'mipmap-mdpi': (48, 108),
    'mipmap-hdpi': (72, 162),
    'mipmap-xhdpi': (96, 216),
    'mipmap-xxhdpi': (144, 324),
    'mipmap-xxxhdpi': (192, 432),
}


def main():
    for folder, (legacy, fg) in DENSITIES.items():
        d = os.path.join(RES, folder)
        os.makedirs(d, exist_ok=True)

        ss = 4 if legacy <= 96 else 3
        write_png(os.path.join(d, 'ic_launcher.png'), legacy, legacy,
                  render(legacy, glyph_ratio=0.58, with_bg=True, ss=ss))

        # 自适应图标前景：透明底，字形留在安全区内
        # （108dp 画布里安全直径 66dp，0.45 时四角刚好不越界）
        ss2 = 4 if fg <= 216 else 3
        write_png(os.path.join(d, 'ic_launcher_foreground.png'), fg, fg,
                  render(fg, glyph_ratio=0.45, with_bg=False, ss=ss2))
        print('done', folder, legacy, fg)

    anydpi = os.path.join(RES, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    adaptive = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
'''
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(anydpi, name), 'w', encoding='utf-8') as f:
            f.write(adaptive)

    values = os.path.join(RES, 'values')
    os.makedirs(values, exist_ok=True)
    with open(os.path.join(values, 'colors.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<resources>\n'
                '    <color name="ic_launcher_background">#B72020</color>\n'
                '</resources>\n')
    print('xml done')


if __name__ == '__main__':
    main()
