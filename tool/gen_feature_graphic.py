"""Generate the Play Store feature graphic: 1024x500, gradient + book logo + copy.

Output: store/feature_graphic.png (PNG, far below the 15 MB cap).
Run:    python tool/gen_feature_graphic.py
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_app_icon import GRAD_BOTTOM, GRAD_TOP, draw_logo, gradient, sparkle

BASE_W, BASE_H = 1024, 500
SS = 4
OUT = os.path.join(os.path.dirname(__file__), "..", "store", "feature_graphic.png")

FONT_LATIN = r"C:\Windows\Fonts\segoeuib.ttf"
FONT_CJK_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"
FONT_CJK = r"C:\Windows\Fonts\msyh.ttc"

TITLE = "AgentBookReader"
TAGLINE = "AI 阅读助手 · 整页翻译 · 智能批注"
FORMATS = "TXT · Markdown · EPUB · PDF · DOCX · CBZ 漫画"
AMBER = (251, 191, 36)


def fit_font(path, text, max_w, start_px):
    px = start_px
    while px > 20:
        f = ImageFont.truetype(path, px)
        w = f.getbbox(text)[2] - f.getbbox(text)[0]
        if w <= max_w:
            return f, w
        px -= 2
    return ImageFont.truetype(path, 20), 20


def rect_gradient(w, h, c1, c2):
    """Diagonal gradient for arbitrary aspect, built small then upscaled."""
    sw, sh = 512, max(1, int(512 * h / w))
    img = Image.new("RGB", (sw, sh))
    px = img.load()
    for y in range(sh):
        for x in range(sw):
            t = (x / (sw - 1) + y / (sh - 1)) / 2
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return img.resize((w, h), Image.BICUBIC)


def main():
    W, H = BASE_W * SS, BASE_H * SS
    img = rect_gradient(W, H, GRAD_TOP, GRAD_BOTTOM).convert("RGBA")

    # soft decorative circles
    deco = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    dd = ImageDraw.Draw(deco)
    dd.ellipse([int(W * 0.62), -int(H * 0.55), int(W * 1.18), int(H * 0.95)],
               fill=(255, 255, 255, 14))
    dd.ellipse([-int(W * 0.05), int(H * 0.72), int(W * 0.35), int(H * 1.5)],
               fill=(255, 255, 255, 10))
    dd.ellipse([int(W * 0.42), int(H * 0.05), int(W * 0.55), int(H * 0.5)],
               outline=(255, 255, 255, 18), width=int(2 * SS))
    deco = deco.filter(ImageFilter.GaussianBlur(int(3 * SS)))
    img.alpha_composite(deco)

    # logo (book + sparkles), cropped to content, left side
    logo = draw_logo(int(760 * SS))
    bbox = logo.getbbox()
    logo = logo.crop(bbox)
    lh = int(320 * SS)
    lw = int(logo.width * lh / logo.height)
    logo = logo.resize((lw, lh), Image.LANCZOS)
    lx, ly = int(58 * SS), (H - lh) // 2 + int(6 * SS)
    img.alpha_composite(logo, (lx, ly))

    d = ImageDraw.Draw(img)
    tx = int(452 * SS)
    max_tw = (BASE_W - 452 - 40) * SS

    # title
    f_title, tw = fit_font(FONT_LATIN, TITLE, max_tw, int(78 * SS))
    tb = f_title.getbbox(TITLE)
    ty = int(128 * SS)
    d.text((tx, ty), TITLE, font=f_title, fill=(255, 255, 255, 255))
    ty2 = ty + (tb[3] - tb[1]) + int(26 * SS)

    # amber accent bar
    bar_y = ty2 + int(10 * SS)
    d.rounded_rectangle([tx + int(2 * SS), bar_y, tx + int(2 * SS) + int(64 * SS),
                         bar_y + int(7 * SS)], radius=int(3.5 * SS), fill=AMBER)

    # tagline
    f_tag, _ = fit_font(FONT_CJK_BOLD, TAGLINE, max_tw, int(40 * SS))
    d.text((tx, bar_y + int(26 * SS)), TAGLINE, font=f_tag,
           fill=(255, 255, 255, 235))

    # supported formats line
    f_fmt, _ = fit_font(FONT_CJK, FORMATS, max_tw, int(27 * SS))
    d.text((tx, bar_y + int(100 * SS)), FORMATS, font=f_fmt,
           fill=(255, 255, 255, 185))

    # a few floating sparkles for balance
    sparkle(d, int(416 * SS), int(96 * SS), int(15 * SS), (255, 255, 255, 200))
    sparkle(d, int(968 * SS), int(430 * SS), int(20 * SS), (255, 255, 255, 170))
    sparkle(d, int(905 * SS), int(60 * SS), int(11 * SS), AMBER + (230,))

    out = img.resize((BASE_W, BASE_H), Image.LANCZOS)
    os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
    out.convert("RGB").save(OUT, "PNG")
    print("saved", os.path.abspath(OUT),
          f"{os.path.getsize(os.path.abspath(OUT)) / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
