#!/usr/bin/env python3
"""Render the VisualSaver macOS app icon (1024 px master).

The artwork is drawn at 3x and downsampled for clean antialiasing.
Output: icon/AppIcon-1024.png
"""

from __future__ import annotations

import math
import random
import shutil
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 3                     # supersampling factor
D = 1024                  # design canvas size
W = D * S
OUT = Path(__file__).resolve().parent


def s(v: float) -> int:
    return int(round(v * S))


def hex_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def linear_gradient(size: tuple[int, int], stops: list[tuple[float, str]]) -> Image.Image:
    """Vertical gradient image covering `size`."""
    w, h = size
    ys = np.linspace(0.0, 1.0, h, dtype=np.float32)
    positions = np.array([p for p, _ in stops], dtype=np.float32)
    cols = np.array([hex_rgb(c) for _, c in stops], dtype=np.float32)
    rgb = np.empty((h, 3), dtype=np.float32)
    for channel in range(3):
        rgb[:, channel] = np.interp(ys, positions, cols[:, channel])
    arr = np.repeat(rgb[:, None, :], w, axis=1).astype(np.uint8)
    return Image.fromarray(arr).convert("RGBA")


def horizontal_gradient(size: tuple[int, int], stops: list[tuple[float, str]]) -> Image.Image:
    w, h = size
    xs = np.linspace(0.0, 1.0, w, dtype=np.float32)
    positions = np.array([p for p, _ in stops], dtype=np.float32)
    cols = np.array([hex_rgb(c) for _, c in stops], dtype=np.float32)
    rgb = np.empty((w, 3), dtype=np.float32)
    for channel in range(3):
        rgb[:, channel] = np.interp(xs, positions, cols[:, channel])
    arr = np.repeat(rgb[None, :, :], h, axis=0).astype(np.uint8)
    return Image.fromarray(arr).convert("RGBA")


def squircle_mask(size: int = W, inset: float = 100.0, exponent: float = 4.8) -> Image.Image:
    """Apple-like superellipse mask, size is full canvas."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    cx = cy = size / 2
    a = (D - inset * 2) * S / 2
    steps = 1000
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, sn = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(c) ** (2 / exponent), c)
        y = cy + a * math.copysign(abs(sn) ** (2 / exponent), sn)
        pts.append((x, y))
    draw.polygon(pts, fill=255)
    return mask


def radial_spot(size: tuple[int, int], center: tuple[float, float],
                diameter: float, color: str, alpha: int) -> Image.Image:
    """Soft circular glow with a true zero-alpha edge."""
    w, h = size
    d = max(2, s(diameter))
    yy, xx = np.mgrid[0:d, 0:d]
    radius = np.sqrt((xx - (d - 1) / 2) ** 2 + (yy - (d - 1) / 2) ** 2) / (d / 2)
    falloff = np.clip(1.0 - radius, 0.0, 1.0)
    falloff = falloff * falloff * (3.0 - 2.0 * falloff)  # smoothstep
    values = (falloff ** 1.7 * alpha).astype(np.uint8)
    grad = Image.fromarray(values, "L")
    mask = Image.new("L", (w, h), 0)
    mask.paste(grad, (s(center[0]) - d // 2, s(center[1]) - d // 2))
    layer = Image.new("RGBA", (w, h), hex_rgb(color) + (255,))
    layer.putalpha(mask)
    return layer


def rounded_mask(box: tuple[float, float, float, float], radius: float) -> Image.Image:
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (s(box[0]), s(box[1]), s(box[2]), s(box[3])), radius=s(radius), fill=255
    )
    return mask


def paste_clipped(base: Image.Image, layer: Image.Image, mask: Image.Image) -> None:
    if layer.size != base.size:
        layer = layer.resize(base.size, Image.Resampling.LANCZOS)
    alpha = ImageChops.multiply(layer.getchannel("A"), mask)
    layer = layer.copy()
    layer.putalpha(alpha)
    base.alpha_composite(layer)


def four_point_star(draw: ImageDraw.ImageDraw, x: float, y: float,
                    radius: float, color: tuple[int, int, int, int]) -> None:
    """Tiny four-point sparkle."""
    thin = radius * 0.16
    draw.polygon([
        (s(x), s(y - radius)),
        (s(x + thin), s(y - thin)),
        (s(x + radius), s(y)),
        (s(x + thin), s(y + thin)),
        (s(x), s(y + radius)),
        (s(x - thin), s(y + thin)),
        (s(x - radius), s(y)),
        (s(x - thin), s(y - thin)),
    ], fill=color)


def main() -> None:
    random.seed(20)

    icon_mask = squircle_mask()

    base = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # --- drop shadow beneath the squircle -----------------------------------
    shadow_mask = icon_mask.filter(ImageFilter.GaussianBlur(s(26)))
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    black = Image.new("RGBA", (W, W), (0, 0, 0, 150))
    shadow.paste(black, (0, s(20)), shadow_mask)
    base.alpha_composite(shadow)

    # --- squircle background ------------------------------------------------
    body = linear_gradient((W, W), [
        (0.00, "#34418C"),
        (0.30, "#1B2159"),
        (0.66, "#101334"),
        (1.00, "#080A19"),
    ])

    # Soft aurora colour glows inside the tile.
    for spot in (
        radial_spot((W, W), (300, 265), 720, "#36D8CF", 78),
        radial_spot((W, W), (760, 700), 760, "#F04C9B", 62),
        radial_spot((W, W), (520, 470), 900, "#6A4CE0", 30),
    ):
        body.alpha_composite(spot)

    # Top glass highlight.
    gloss = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.ellipse((s(90), s(-330), s(934), s(430)), fill=(255, 255, 255, 22))
    gloss = gloss.filter(ImageFilter.GaussianBlur(s(45)))
    body.alpha_composite(gloss)

    body.putalpha(ImageChops.multiply(body.getchannel("A"), icon_mask))
    base.alpha_composite(body)

    # --- tiny ambient sparkles around the monitor ---------------------------
    spark = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spark)
    four_point_star(sd, 266, 232, 17, (210, 246, 255, 165))
    four_point_star(sd, 792, 232, 10, (255, 226, 245, 120))
    four_point_star(sd, 804, 752, 14, (255, 224, 241, 120))
    spark = spark.filter(ImageFilter.GaussianBlur(s(0.8)))
    base.alpha_composite(spark)

    # --- monitor shadow -----------------------------------------------------
    mon_shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    md = ImageDraw.Draw(mon_shadow)
    md.rounded_rectangle((s(196), s(306), s(828), s(680)), radius=s(48), fill=(0, 0, 0, 120))
    md.rounded_rectangle((s(388), s(708), s(636), s(752)), radius=s(22), fill=(0, 0, 0, 110))
    mon_shadow = mon_shadow.filter(ImageFilter.GaussianBlur(s(22)))
    base.alpha_composite(mon_shadow)

    # soft backlight separating the dark monitor from the tile
    backlight = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(backlight).rounded_rectangle(
        (s(172), s(276), s(852), s(672)), radius=s(62), fill=(104, 156, 255, 46))
    backlight = backlight.filter(ImageFilter.GaussianBlur(s(30)))
    base.alpha_composite(backlight)

    # --- monitor stand ------------------------------------------------------
    stand = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stand)
    # neck
    sd.polygon([
        (s(468), s(648)), (s(556), s(648)), (s(570), s(716)), (s(454), s(716)),
    ], fill=(18, 22, 38, 255))
    # base
    sd.rounded_rectangle((s(372), s(712), s(652), s(744)), radius=s(16), fill=(16, 19, 33, 255))
    base.alpha_composite(stand)

    stand_gloss = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(stand_gloss)
    gd.rounded_rectangle((s(380), s(714), s(644), s(722)), radius=s(5), fill=(154, 177, 214, 55))
    gd.polygon([(s(472), s(652)), (s(500), s(652)), (s(474), s(710)), (s(458), s(710))],
               fill=(140, 165, 205, 30))
    base.alpha_composite(stand_gloss)

    # --- screen frame -------------------------------------------------------
    frame = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle((s(180), s(284), s(844), s(664)), radius=s(56),
                         fill=(24, 29, 48, 255))
    # inner bevel
    fd.rounded_rectangle((s(180), s(284), s(844), s(664)), radius=s(56),
                         outline=(255, 255, 255, 54), width=s(2.4))
    fd.rounded_rectangle((s(188), s(292), s(836), s(656)), radius=s(49),
                         outline=(4, 7, 14, 190), width=s(3))
    base.alpha_composite(frame)

    # frame top highlight
    frame_gloss = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(frame_gloss)
    gd.rounded_rectangle((s(190), s(288), s(834), s(360)), radius=s(46),
                         fill=(255, 255, 255, 13))
    frame_gloss = frame_gloss.filter(ImageFilter.GaussianBlur(s(10)))
    screen_outer_mask = rounded_mask((180, 284, 844, 664), 56)
    paste_clipped(base, frame_gloss, screen_outer_mask)

    # --- screen content -----------------------------------------------------
    left, top, right, bottom = 193.0, 297.0, 831.0, 651.0
    scr_w, scr_h = right - left, bottom - top
    screen_mask = rounded_mask((left, top, right, bottom), 44)

    scr = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    vertical = linear_gradient((s(scr_w), s(scr_h)), [
        (0.00, "#1B123F"),
        (0.24, "#3B1E68"),
        (0.46, "#743183"),
        (0.62, "#B8448B"),
        (0.72, "#EF6F83"),
        (0.78, "#FFB27E"),
        (0.84, "#48224F"),
        (0.92, "#1B1333"),
        (1.00, "#0B0817"),
    ])
    scr.paste(vertical, (s(left), s(top)))

    # sun glow + sun
    sun_x, sun_y = 698.0, 536.0
    scr.alpha_composite(radial_spot((W, W), (sun_x, sun_y), 400, "#FFCF8F", 100))
    sun = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sud = ImageDraw.Draw(sun)
    sud.ellipse((s(sun_x - 70), s(sun_y - 70), s(sun_x + 70), s(sun_y + 70)), fill=(255, 236, 186, 255))
    sun_inner = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sid = ImageDraw.Draw(sun_inner)
    sid.ellipse((s(sun_x - 50), s(sun_y - 56), s(sun_x + 50), s(sun_y + 42)), fill=(255, 248, 221, 255))
    sun.alpha_composite(sun_inner.filter(ImageFilter.GaussianBlur(s(8))))
    scr.alpha_composite(sun)

    # aurora ribbons sweeping through the sky
    for y0, thickness, shift, alpha, stops in (
        (382, 42, 0.0, 72, [(0, "#59F4E1"), (0.55, "#4DB8FF"), (1, "#B36BFF")]),
        (446, 30, 1.7, 52, [(0, "#7BF7DB"), (0.5, "#7D7BFF"), (1, "#FF6FC8")]),
    ):
        ribbon_mask = Image.new("L", (W, W), 0)
        rd = ImageDraw.Draw(ribbon_mask)
        top_pts, bottom_pts = [], []
        for i in range(121):
            x = left - 10 + (scr_w + 20) * i / 120
            t = (x - left) / scr_w
            ty = (y0 + 34 * math.sin(t * 5.4 + 0.9 + shift)
                  + 13 * math.sin(t * 13.7 + 2.4 + shift)
                  + 26 * (t - 0.5))
            by = ty + thickness + 16 * math.sin(t * 7.1 + 3.2 + shift)
            top_pts.append((s(x), s(ty)))
            bottom_pts.append((s(x), s(by)))
        rd.polygon(top_pts + bottom_pts[::-1], fill=255)
        ribbon_mask = ribbon_mask.filter(ImageFilter.GaussianBlur(s(9)))
        ribbon_mask = ribbon_mask.point(lambda v, a=alpha: v * a // 255)
        ribbon = horizontal_gradient((W, W), stops)
        ribbon.putalpha(ribbon_mask)
        scr.alpha_composite(ribbon)

    # stars
    star_positions = []
    for _ in range(46):
        x = random.uniform(left + 14, right - 14)
        y = random.uniform(top + 12, top + scr_h * 0.52)
        r = random.uniform(1.0, 2.6)
        a = random.randint(70, 210)
        star_positions.append((x, y, r, a))

    halos = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halos)
    for x, y, r, a in ((300, 338, 3.4, 210), (690, 372, 2.8, 170), (612, 322, 2.2, 140)):
        hd.ellipse((s(x - r * 4.5), s(y - r * 4.5), s(x + r * 4.5), s(y + r * 4.5)),
                   fill=(180, 225, 255, a // 5))
    halos = halos.filter(ImageFilter.GaussianBlur(s(4)))
    scr.alpha_composite(halos)

    stars = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    std = ImageDraw.Draw(stars)
    for x, y, r, a in star_positions:
        std.ellipse((s(x - r), s(y - r), s(x + r), s(y + r)), fill=(255, 255, 255, a))
    for x, y, r, a in ((300, 338, 3.4, 210), (690, 372, 2.8, 170), (612, 322, 2.2, 140)):
        std.ellipse((s(x - r), s(y - r), s(x + r), s(y + r)), fill=(255, 255, 255, a))
    stars = stars.filter(ImageFilter.GaussianBlur(s(0.5)))
    scr.alpha_composite(stars)

    # thin clouds near the horizon
    clouds = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    cd = ImageDraw.Draw(clouds)
    for cx, cy, w, h, a in ((392, 558, 430, 17, 44), (636, 574, 320, 13, 36), (510, 594, 520, 10, 28)):
        cd.ellipse((s(cx - w / 2), s(cy - h / 2), s(cx + w / 2), s(cy + h / 2)),
                   fill=(255, 205, 196, a))
    clouds = clouds.filter(ImageFilter.GaussianBlur(s(7)))
    scr.alpha_composite(clouds)

    # layered hills
    hill_layers = (
        (543, [(118, 27, 1.15), (47, 12, 0.4), (240, 16, 2.3)], "#553579", 255),
        (578, [(145, 34, 2.5), (61, 15, 1.3), (300, 12, 0.2)], "#30205A", 255),
        (620, [(105, 28, 4.1), (44, 13, 2.6), (260, 9, 1.1)], "#151029", 255),
    )
    for base_y, waves, color, alpha in hill_layers:
        pts = []
        for i in range(121):
            x = left - 10 + (scr_w + 20) * i / 120
            y = base_y
            for wavelength, amp, phase in waves:
                y += amp * math.sin((x - left) / wavelength + phase)
            pts.append((s(x), s(y)))
        pts += [(s(right + 10), s(bottom + 10)), (s(left - 10), s(bottom + 10))]
        layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon(pts, fill=hex_rgb(color) + (alpha,))
        scr.alpha_composite(layer)

    # crest light on the nearest hill
    crest = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    cd = ImageDraw.Draw(crest)
    pts = []
    for i in range(121):
        x = left - 10 + (scr_w + 20) * i / 120
        y = 620
        for wavelength, amp, phase in [(105, 28, 4.1), (44, 13, 2.6), (260, 9, 1.1)]:
            y += amp * math.sin((x - left) / wavelength + phase)
        pts.append((s(x), s(y)))
    cd.line(pts, fill=(155, 240, 233, 70), width=s(1.6), joint="curve")
    crest = crest.filter(ImageFilter.GaussianBlur(s(1.4)))
    scr.alpha_composite(crest)

    # screen glass reflection
    glass = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glass)
    gd.polygon([(s(left), s(top + 165)), (s(right), s(top - 40)),
                (s(right), s(top + 70)), (s(left), s(top + 290))],
               fill=(255, 255, 255, 16))
    glass = glass.filter(ImageFilter.GaussianBlur(s(16)))
    scr.alpha_composite(glass)

    # inner rim shadow
    rim = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    rd.rounded_rectangle((s(left), s(top), s(right), s(bottom)), radius=s(44),
                         outline=(0, 0, 0, 120), width=s(3))
    scr.alpha_composite(rim)

    # clip everything to the screen
    scr.putalpha(ImageChops.multiply(scr.getchannel("A"), screen_mask))
    base.alpha_composite(scr)

    # crisp screen border and tiny top highlight
    border = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    bd = ImageDraw.Draw(border)
    bd.rounded_rectangle((s(left), s(top), s(right), s(bottom)), radius=s(44),
                         outline=(7, 10, 18, 200), width=s(2))
    base.alpha_composite(border)

    # --- glass play button --------------------------------------------------
    cx, cy, r = 512, 474, 62
    glow = radial_spot((W, W), (cx, cy), 300, "#BCEFFF", 42)
    base.alpha_composite(glow)

    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        (s(cx - r), s(cy - r + 10), s(cx + r), s(cy + r + 10)), fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(s(14)))
    base.alpha_composite(shadow)

    disc_mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(disc_mask).ellipse((s(cx - r), s(cy - r), s(cx + r), s(cy + r)), fill=255)
    disc = linear_gradient((W, W), [(0.0, "#FFFFFF"), (1.0, "#9FB6C9")])
    disc.putalpha(disc_mask.point(lambda v: int(v * 0.36)))
    base.alpha_composite(disc)

    ring = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse((s(cx - r), s(cy - r), s(cx + r), s(cy + r)),
                                 outline=(255, 255, 255, 175), width=s(2.2))
    base.alpha_composite(ring)

    # top highlight on the button
    btn_gloss = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(btn_gloss).ellipse(
        (s(cx - r + 12), s(cy - r + 8), s(cx + r - 12), s(cy + 8)),
        fill=(255, 255, 255, 48))
    btn_gloss = btn_gloss.filter(ImageFilter.GaussianBlur(s(7)))
    btn_gloss.putalpha(ImageChops.multiply(btn_gloss.getchannel("A"), disc_mask))
    base.alpha_composite(btn_gloss)

    # play triangle (optically centred)
    tri = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    td = ImageDraw.Draw(tri)
    td.polygon([(s(497), s(443)), (s(497), s(505)), (s(555), s(474))],
               fill=(255, 255, 255, 245))
    tri = tri.filter(ImageFilter.GaussianBlur(s(0.7)))
    base.alpha_composite(tri)

    # --- final subtle grain and downsample ----------------------------------
    final = base.resize((D, D), Image.Resampling.LANCZOS)

    arr = np.asarray(final.convert("RGB"), dtype=np.int16)
    rng = np.random.default_rng(7)
    noise = rng.integers(-1, 2, size=arr.shape[:2] + (1,), dtype=np.int16)
    arr = np.clip(arr + noise, 0, 255).astype(np.uint8)
    rgb = Image.fromarray(arr).convert("RGBA")
    rgb.putalpha(final.getchannel("A"))
    rgb.save(OUT / "AppIcon-1024.png")

    # --- build the .icns ----------------------------------------------------
    iconset = OUT / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()

    representations = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, size in representations.items():
        rgb.resize((size, size), Image.Resampling.LANCZOS).save(iconset / name)

    icns_path = OUT.parent / "VisualSaver" / "AppIcon.icns"
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
        check=True,
    )
    shutil.rmtree(iconset)

    print("wrote", OUT / "AppIcon-1024.png")
    print("wrote", icns_path)


if __name__ == "__main__":
    main()
