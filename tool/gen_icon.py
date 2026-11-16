# -*- coding: utf-8 -*-
"""生成「薪迹」应用图标：红底 + 立体 X。

为什么用纯 Python 画而不是调图像库：
  这台机器没装 Pillow，装它又要走代理。图标本身是纯几何图形，
  自己写光栅化 + PNG 编码（zlib 是标准库）反而最可控、零依赖。

设计说明：
  - 底色：深红竖向渐变，顶部略亮，有体积感
  - 主体：两笔交叉的 X，圆角、带斜面高光
  - 立体：先在右下方画一层深红"厚度"，再叠主体，形成挤出效果
"""
import math
import os
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


# ---------------------------------------------------------------- 光栅化

BG_TOP = (211, 47, 47)
BG_BOTTOM = (142, 16, 16)
X_TOP = (255, 252, 249)
X_BOTTOM = (236, 166, 148)
X_SHADOW = (86, 8, 8)

SQ2 = math.sqrt(0.5)


def _bar_hit(px, py, cx, cy, ux, uy, half_len, half_thk, cap_extra=0.0):
    """点是否落在以 (cx,cy) 为中心、方向 (ux,uy) 的圆角粗线内。
    返回 (是否命中, 归一化横向距离 0=中轴 1=边缘)"""
    dx, dy = px - cx, py - cy
    t = dx * ux + dy * uy           # 沿轴投影
    d = abs(-dx * uy + dy * ux)     # 垂轴距离
    if abs(t) <= half_len and d <= half_thk:
        return True, d / half_thk
    # 两端圆头
    if abs(t) > half_len:
        ex = cx + ux * half_len * (1 if t > 0 else -1)
        ey = cy + uy * half_len * (1 if t > 0 else -1)
        dist = math.hypot(px - ex, py - ey)
        if dist <= half_thk:
            return True, dist / half_thk
    return False, 0.0


def _x_coverage(px, py, scale):
    """返回 (是否在 X 内, 斜面强度 0..1)"""
    cx = cy = 0.5
    half_len = 0.355 * scale
    half_thk = 0.088 * scale
    best = None
    for ux, uy in ((SQ2, SQ2), (SQ2, -SQ2)):
        hit, bevel = _bar_hit(px, py, cx, cy, ux, uy, half_len, half_thk)
        if hit:
            if best is None or bevel < best:
                best = bevel
    if best is None:
        return False, 0.0
    return True, best


def _lerp(a, b, k):
    k = max(0.0, min(1.0, k))
    return tuple(int(a[i] + (b[i] - a[i]) * k) for i in range(3))


def _shade_x(y, bevel, scale):
    """X 本体的颜色：上亮下暗 + 边缘压暗做出斜面"""
    base = _lerp(X_TOP, X_BOTTOM, (y - (0.5 - 0.36 * scale)) / max(1e-6, 0.72 * scale))
    # 边缘压暗（模拟倒角）
    dark = tuple(int(c * (1.0 - 0.42 * (bevel ** 1.6))) for c in base)
    # 中轴顶部再补一点高光
    if bevel < 0.30 and y < 0.46:
        boost = 1.0 - bevel / 0.30
        dark = tuple(int(min(255, c + 30 * boost)) for c in dark)
    return dark


def render(size, scale=1.0, with_bg=True, ss=3):
    """渲染一张 size×size 的 RGBA 图标（ss 倍超采样抗锯齿）"""
    big = size * ss
    buf = bytearray(big * big * 4)

    # 立体厚度：整体向右下偏移
    off_x = 0.030 * scale
    off_y = 0.036 * scale

    for py in range(big):
        fy = (py + 0.5) / big
        for px in range(big):
            fx = (px + 0.5) / big
            i = (py * big + px) * 4

            if with_bg:
                # 竖向渐变 + 顶部中央柔光
                r, g, b = _lerp(BG_TOP, BG_BOTTOM, fy ** 0.85)
                halo = max(0.0, 1.0 - math.hypot(fx - 0.5, fy - 0.32) / 0.62)
                halo = halo ** 2 * 0.30
                r = int(r + (255 - r) * halo * 0.45)
                g = int(g + (255 - g) * halo * 0.30)
                b = int(b + (255 - b) * halo * 0.30)
                a = 255
            else:
                r = g = b = 0
                a = 0

            # 先画阴影层
            hit_s, bv_s = _x_coverage(fx - off_x, fy - off_y, scale)
            if hit_s:
                r, g, b = X_SHADOW
                a = 255

            # 再画主体
            hit, bv = _x_coverage(fx, fy, scale)
            if hit:
                r, g, b = _shade_x(fy, bv, scale)
                a = 255

            buf[i] = r
            buf[i + 1] = g
            buf[i + 2] = b
            buf[i + 3] = a

    # 盒式降采样
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

        ss = 3 if legacy <= 96 else 2
        write_png(os.path.join(d, 'ic_launcher.png'), legacy, legacy,
                  render(legacy, scale=1.0, with_bg=True, ss=ss))

        # 自适应图标前景：透明底，X 缩到安全区内（约 66/108）
        ss2 = 3 if fg <= 216 else 2
        write_png(os.path.join(d, 'ic_launcher_foreground.png'), fg, fg,
                  render(fg, scale=0.80, with_bg=False, ss=ss2))
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
