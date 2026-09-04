"""Generate AgentBookReader launcher icons (open book + AI sparkle).

Outputs into assets/icon/:
  app_icon.png             1024, rounded corners with transparency (legacy launcher)
  app_icon_foreground.png  1024, transparent, logo recentered (adaptive foreground)
  app_icon_background.png  1024, full-bleed gradient (adaptive background)
  play_store_512.png       512,  full-bleed square (Play Console listing)

Run: python tool/gen_app_icon.py
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

BASE = 1024
SS = 4  # supersample factor
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "icon")

GRAD_TOP = (99, 102, 241)    # indigo-500
GRAD_BOTTOM = (147, 51, 234)  # purple-600
COVER = (49, 42, 107)        # deep indigo cover
PAGE_L = (255, 255, 255)
PAGE_R = (243, 239, 251)
LINE_L = (199, 181, 245)
LINE_R = (216, 203, 240)
AMBER = (251, 191, 36)
AMBER_DEEP = (245, 158, 11)


def lerp(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))


def gradient(size, c1, c2):
    """Smooth diagonal gradient built small then upscaled."""
    small = 512
    img = Image.new("RGB", (small, small))
    px = img.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * small - 2)
            px[x, y] = lerp(c1, c2, t)
    return img.resize((size, size), Image.BICUBIC)


def rounded_page(w, h, radius, fill, lines, line_color, line_gaps):
    """A page: rounded rect with horizontal text bars, in local coords."""
    img = Image.new("RGBA", (w + radius * 2, h + radius * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    ox, oy = radius, radius
    d.rounded_rectangle([ox, oy, ox + w, oy + h], radius=radius, fill=fill)
    lw = h // 60
    for i, (y, width) in enumerate(lines):
        x0 = ox + w // 6
        color = lerp(line_color, fill, 0.25) if i == len(lines) - 1 else line_color
        d.rounded_rectangle(
            [x0, oy + y, x0 + width, oy + y + lw], radius=lw // 2, fill=color
        )
    return img


def sparkle(d, cx, cy, r, fill):
    """Four-point star (AI glint)."""
    k = r * 0.16
    pts = [
        (cx, cy - r), (cx + k, cy - k), (cx + r, cy), (cx + k, cy + k),
        (cx, cy + r), (cx - k, cy + k), (cx - r, cy), (cx - k, cy - k),
    ]
    d.polygon(pts, fill=fill)


def draw_logo(size):
    """Logo composition (book + sparkles) on transparent RGBA, design space 1024."""
    f = size / BASE
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # ground shadow
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse([int(512 * f - 240 * f), int(770 * f), int(512 * f + 240 * f),
                int(770 * f + 70 * f)], fill=(20, 10, 60, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(22 * f)))
    img.alpha_composite(shadow)

    def paste_rotated(layer, angle, cx, cy):
        rot = layer.rotate(angle, expand=True, resample=Image.BICUBIC)
        img.alpha_composite(rot, (int(cx * f - rot.width / 2),
                                  int(cy * f - rot.height / 2)))

    pw, ph, pr = int(258 * f), int(344 * f), int(26 * f)
    lines = [(int(84 * f), int(180 * f)), (int(134 * f), int(152 * f)),
             (int(184 * f), int(104 * f))]

    # cover underneath each page (dark border effect)
    cover = rounded_page(int(pw + 30 * f), int(ph + 30 * f), int(pr + 8 * f),
                         COVER, [], None, None)
    paste_rotated(cover, 8, 640, 566)
    paste_rotated(cover, -8, 384, 566)

    page_r = rounded_page(pw, ph, pr, PAGE_R, lines, LINE_R, None)
    page_l = rounded_page(pw, ph, pr, PAGE_L, lines, LINE_L, None)
    paste_rotated(page_r, 8, 634, 562)
    paste_rotated(page_l, -8, 390, 562)

    # spine crease
    sp = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    spd = ImageDraw.Draw(sp)
    spd.rounded_rectangle([int(508 * f), int(436 * f), int(516 * f), int(724 * f)],
                          radius=int(4 * f), fill=(90, 70, 160, 110))
    sp = sp.filter(ImageFilter.GaussianBlur(int(3 * f)))
    img.alpha_composite(sp)

    # AI sparkles
    d = ImageDraw.Draw(img)
    sparkle(d, int(748 * f), int(294 * f), int(96 * f), AMBER)
    sparkle(d, int(748 * f), int(294 * f), int(31 * f), (255, 248, 220, 255))
    sparkle(d, int(268 * f), int(304 * f), int(44 * f), (255, 255, 255, 210))

    return img


def compose_legacy():
    """Rounded gradient background + logo (legacy launcher icon)."""
    W = BASE * SS
    bg = gradient(W, GRAD_TOP, GRAD_BOTTOM).convert("RGBA")

    # soft top-left glow for depth
    glow = Image.new("L", (W, W), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-W // 3, -W // 3, W // 2, W // 2], fill=46)
    glow = glow.filter(ImageFilter.GaussianBlur(W // 8))
    white = Image.new("RGBA", (W, W), (255, 255, 255, 255))
    bg = Image.composite(white, bg, glow)

    logo = draw_logo(W)
    bbox = logo.getbbox()
    lw, lh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    cx, cy = (bbox[0] + bbox[2]) // 2, (bbox[1] + bbox[3]) // 2
    pos = (W // 2 - cx, W // 2 - cy + int(14 * SS))
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    layer.alpha_composite(logo, pos)
    img = Image.alpha_composite(bg, layer)

    mask = Image.new("L", (W, W), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, W - 1, W - 1], radius=int(224 * SS), fill=255)
    out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out.resize((BASE, BASE), Image.LANCZOS)


def compose_foreground():
    """Logo recentered on transparent canvas (adaptive foreground)."""
    W = BASE * SS
    logo = draw_logo(int(W * 0.98))
    bbox = logo.getbbox()
    lw, lh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    # keep composition inside the adaptive safe zone (~66% circle)
    scale = min(1.0, (W * 0.60) / max(lw, lh))
    if scale < 1.0:
        logo = logo.resize((int(logo.width * scale), int(logo.height * scale)),
                           Image.LANCZOS)
        bbox = logo.getbbox()
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    cx, cy = (bbox[0] + bbox[2]) // 2, (bbox[1] + bbox[3]) // 2
    layer.alpha_composite(logo, (W // 2 - cx, W // 2 - cy))
    return layer.resize((BASE, BASE), Image.LANCZOS)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    legacy = compose_legacy()
    legacy.save(os.path.join(OUT_DIR, "app_icon.png"))

    fg = compose_foreground()
    fg.save(os.path.join(OUT_DIR, "app_icon_foreground.png"))

    bg = gradient(BASE, GRAD_TOP, GRAD_BOTTOM)
    bg.save(os.path.join(OUT_DIR, "app_icon_background.png"))

    full = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    full.alpha_composite(bg.convert("RGBA"))
    logo = draw_logo(BASE)
    bbox = logo.getbbox()
    cx, cy = (bbox[0] + bbox[2]) // 2, (bbox[1] + bbox[3]) // 2
    full.alpha_composite(logo, (BASE // 2 - cx, BASE // 2 - cy + 14))
    full.resize((512, 512), Image.LANCZOS).convert("RGB").save(
        os.path.join(OUT_DIR, "play_store_512.png"))

    print("written to", os.path.abspath(OUT_DIR))


if __name__ == "__main__":
    main()
