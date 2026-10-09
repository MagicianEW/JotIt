# -*- coding: utf-8 -*-
"""Generates the JotIt application icon.

Design: a sheet of note paper with text lines, an angled pencil about to
write the next line, on an ink-blue gradient tile. Drawn at 4x and
down-sampled so small sizes stay crisp.

Outputs:
  windows/runner/resources/app_icon.ico  (256..16, consumed by Runner.rc)
  tool/icon_preview_1024.png             (for review)
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048  # supersampled canvas
RADIUS = 400
OUT_ICO = os.path.join(os.path.dirname(__file__), "..",
                       "windows", "runner", "resources", "app_icon.ico")
OUT_PNG = os.path.join(os.path.dirname(__file__), "icon_preview_1024.png")

INK_TOP = (31, 78, 121)     # #1F4E79
INK_BOT = (18, 48, 76)      # #12304C
PAPER = (249, 251, 253)     # #F9FBFD
PAPER_EDGE = (214, 224, 235)
LINE = (196, 208, 222)      # #C4D0DE
LINE_HEAD = (143, 163, 184)  # #8FA3B8
FOLD = (219, 228, 238)
PENCIL = (246, 185, 59)     # #F6B93B
PENCIL_DARK = (222, 158, 40)
FERRULE = (176, 190, 201)
WOOD = (91, 103, 112)       # #5B6770
LEAD = (43, 49, 56)         # #2B3138
SHADOW = (0, 0, 0)


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def gradient_tile():
    small = Image.new("RGB", (2, 2))
    small.putpixel((0, 0), INK_TOP)
    small.putpixel((0, 1), INK_TOP)
    small.putpixel((1, 0), INK_BOT)
    small.putpixel((1, 1), INK_BOT)
    # Diagonal gradient: interpolate by hand on a 256px strip, then scale.
    g = Image.new("RGB", (256, 256))
    px = g.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510.0
            px[x, y] = tuple(int(INK_TOP[i] + (INK_BOT[i] - INK_TOP[i]) * t)
                             for i in range(3))
    return g.resize((S, S), Image.BILINEAR)


def rot(cx, cy, t, w, ux, uy, vx, vy):
    """Point at axis offset t, half-width offset w, around (cx, cy)."""
    return (cx + ux * t + vx * w, cy + uy * t + vy * w)


def draw_pencil(img, cx, cy, length, width, angle_deg=45):
    """Pencil pointing up-left along `angle_deg`; (cx, cy) is the tip."""
    a = math.radians(angle_deg)
    ux, uy = math.cos(a), -math.sin(a)     # tail-ward direction
    vx, vy = -uy, ux                        # perpendicular
    tip_t = 0.0
    lead_t = length * 0.13                  # graphite tip
    wood_t = length * 0.22                  # wood cone end
    ferrule_t = length * 0.30               # ferrule end
    tail_t = length
    half = width / 2

    d = ImageDraw.Draw(img)
    # Shadow under the pencil
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    for (t0, t1, w) in [(tip_t, tail_t, half)]:
        sd.polygon([rot(cx, cy, t0, -w, ux, uy, vx, vy),
                    rot(cx, cy, t1, -w, ux, uy, vx, vy),
                    rot(cx, cy, t1, w, ux, uy, vx, vy),
                    rot(cx, cy, t0, w, ux, uy, vx, vy)],
                   fill=(0, 0, 0, 70))
    sh = sh.filter(ImageFilter.GaussianBlur(12))
    img.alpha_composite(sh)

    # Wood cone (from lead base to ferrule edge)
    d.polygon([rot(cx, cy, tip_t, 0, ux, uy, vx, vy),
               rot(cx, cy, wood_t, -half, ux, uy, vx, vy),
               rot(cx, cy, wood_t, half, ux, uy, vx, vy)], fill=WOOD)
    # Graphite lead
    d.polygon([rot(cx, cy, tip_t, 0, ux, uy, vx, vy),
               rot(cx, cy, lead_t, -half * 0.45, ux, uy, vx, vy),
               rot(cx, cy, lead_t, half * 0.45, ux, uy, vx, vy)], fill=LEAD)
    # Barrel with a darker lower edge for depth (two lengthwise strips)
    d.polygon([rot(cx, cy, wood_t, -half, ux, uy, vx, vy),
               rot(cx, cy, ferrule_t, -half, ux, uy, vx, vy),
               rot(cx, cy, tail_t, -half, ux, uy, vx, vy),
               rot(cx, cy, tail_t, -half, ux, uy, vx, vy)], fill=PENCIL)
    d.polygon([rot(cx, cy, wood_t, -half, ux, uy, vx, vy),
               rot(cx, cy, tail_t, -half, ux, uy, vx, vy),
               rot(cx, cy, tail_t, half, ux, uy, vx, vy),
               rot(cx, cy, wood_t, half, ux, uy, vx, vy)], fill=PENCIL)
    d.polygon([rot(cx, cy, wood_t, half * 0.1, ux, uy, vx, vy),
               rot(cx, cy, tail_t, half * 0.1, ux, uy, vx, vy),
               rot(cx, cy, tail_t, half, ux, uy, vx, vy),
               rot(cx, cy, wood_t, half, ux, uy, vx, vy)],
              fill=PENCIL_DARK)
    # Tail end cap
    d.polygon([rot(cx, cy, tail_t, -half, ux, uy, vx, vy),
               rot(cx, cy, tail_t - width * 0.16, -half, ux, uy, vx, vy),
               rot(cx, cy, tail_t - width * 0.16, half, ux, uy, vx, vy),
               rot(cx, cy, tail_t, half, ux, uy, vx, vy)], fill=PENCIL_DARK)
    # Ferrule band
    d.polygon([rot(cx, cy, wood_t, -half * 0.92, ux, uy, vx, vy),
               rot(cx, cy, ferrule_t, -half * 0.92, ux, uy, vx, vy),
               rot(cx, cy, ferrule_t, half * 0.92, ux, uy, vx, vy),
               rot(cx, cy, wood_t, half * 0.92, ux, uy, vx, vy)],
              fill=FERRULE)


def build():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tile = gradient_tile().convert("RGBA")
    mask = rounded_mask(S, RADIUS)
    img.paste(tile, (0, 0), mask)

    # --- subtle inner highlight (top edge sheen) ---
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.rounded_rectangle([0, 0, S - 1, S - 1], radius=RADIUS,
                         outline=(255, 255, 255, 26), width=18)
    img.alpha_composite(sheen)

    # --- paper sheet with folded corner ---
    px0, py0, px1, py1 = int(S * 0.20), int(S * 0.16), int(S * 0.74), int(S * 0.82)
    fold = int(S * 0.13)
    pad = 60  # room for the blur
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shm = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shm).rounded_rectangle(
        [px0, py0 + 26, px1, py1 + 26], radius=90, fill=110)
    shadow.paste((0, 0, 0, 110), (0, 0), shm)
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    # Keep the shadow inside the tile.
    r, g, b, a = shadow.split()
    a = Image.composite(a, Image.new("L", (S, S), 0), mask)
    shadow = Image.merge("RGBA", (r, g, b, a))
    img.alpha_composite(shadow)

    page_mask = Image.new("L", (S, S), 0)
    pd = ImageDraw.Draw(page_mask)
    pd.rounded_rectangle([px0, py0, px1, py1], radius=70, fill=255)
    # Cut the folded corner out of the page (transparent notch).
    pd.polygon([(px1, py1 - fold), (px1, py1), (px1 - fold, py1)], fill=0)
    paper = Image.new("RGBA", (S, S), PAPER + (255,))
    img.paste(paper, (0, 0), page_mask)
    # Thin edge for definition against light backgrounds at small sizes.
    edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    ed.rounded_rectangle([px0, py0, px1, py1], radius=70,
                         outline=(*PAPER_EDGE, 255), width=8)
    img.alpha_composite(Image.composite(edge, Image.new("RGBA", (S, S), (0, 0, 0, 0)), page_mask))
    # Fold triangle (the turned-up corner).
    d = ImageDraw.Draw(img)
    d.polygon([(px1, py1 - fold), (px1 - fold, py1), (px1 - fold, py1 - fold)],
              fill=FOLD)

    # --- text lines (rounded, one highlighted as a heading) ---
    def line(y, x0, x1, color, thick):
        d.rounded_rectangle([x0, y - thick // 2, x1, y + thick // 2],
                            radius=thick // 2, fill=color)

    lx0 = px0 + int(S * 0.055)
    lx1 = px1 - int(S * 0.075)
    rows = [
        (py0 + int(S * 0.115), 0.62, LINE_HEAD, 26),
        (py0 + int(S * 0.205), 1.0, LINE, 22),
        (py0 + int(S * 0.29), 1.0, LINE, 22),
        (py0 + int(S * 0.375), 0.78, LINE, 22),
    ]
    for (y, frac, color, thick) in rows:
        line(y, lx0, lx0 + int((lx1 - lx0) * frac), color, thick)

    # --- pencil, tip resting on the sheet where the next line would go ---
    tip_x = px1 - int(S * 0.17)
    tip_y = py1 - int(S * 0.17)
    draw_pencil(img, tip_x, tip_y,
                length=int(S * 0.38), width=int(S * 0.075), angle_deg=45)

    # --- clip everything to the rounded tile ---
    r, g, b, a = img.split()
    a = ImageChops.multiply(a, mask)
    img = Image.merge("RGBA", (r, g, b, a))

    # --- downsample & export ---
    final = img.resize((1024, 1024), Image.LANCZOS)
    os.makedirs(os.path.dirname(OUT_PNG), exist_ok=True)
    final.save(OUT_PNG)

    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
                 (128, 128), (256, 256)]
    img.resize((256, 256), Image.LANCZOS).save(
        os.path.abspath(OUT_ICO), format="ICO", sizes=ico_sizes)
    print("icon written:", os.path.abspath(OUT_ICO), "|", OUT_PNG)


if __name__ == "__main__":
    build()
