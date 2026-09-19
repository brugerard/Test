#!/usr/bin/env python3
"""Generates the 1024x1024 App Store icon for FileTypeBrowser."""

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = "/home/user/Test/FileTypeBrowser/FileTypeBrowser/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def make_background():
    # 2x2 corner-color seed, upscaled with bicubic interpolation for a
    # smooth diagonal gradient (no numpy needed).
    seed = Image.new("RGB", (2, 2))
    seed.putpixel((0, 0), (90, 140, 247))    # top-left: bright blue
    seed.putpixel((1, 0), (99, 122, 245))    # top-right: blue-violet
    seed.putpixel((0, 1), (108, 99, 235))    # bottom-left: violet
    seed.putpixel((1, 1), (124, 92, 231))    # bottom-right: deep indigo
    return seed.resize((SIZE, SIZE), Image.BICUBIC)


def rounded_rect(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def main():
    img = make_background()
    draw = ImageDraw.Draw(img, "RGBA")

    cx, cy = SIZE / 2, SIZE / 2

    # --- soft shadow beneath the folder glyph ---
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    body_w, body_h = 560, 400
    body_top = cy - body_h * 0.32
    rounded_rect(
        sdraw,
        (cx - body_w / 2, body_top, cx + body_w / 2, body_top + body_h),
        56,
        (20, 20, 50, 140),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    shadow_offset = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_offset.paste(shadow, (0, 22), shadow)
    img = Image.alpha_composite(img.convert("RGBA"), shadow_offset)
    draw = ImageDraw.Draw(img, "RGBA")

    # --- folder tab ---
    tab_w, tab_h = 230, 70
    tab_left = cx - body_w / 2 + 26
    tab_top = body_top - tab_h + 22
    rounded_rect(
        draw,
        (tab_left, tab_top, tab_left + tab_w, tab_top + tab_h),
        26,
        (255, 255, 255, 255),
    )

    # --- folder body ---
    rounded_rect(
        draw,
        (cx - body_w / 2, body_top, cx + body_w / 2, body_top + body_h),
        56,
        (255, 255, 255, 255),
    )

    # --- four "file type" tag dots along the bottom edge of the folder,
    # slightly overlapping it, hinting at grouping-by-type ---
    dot_colors = [
        (255, 107, 107, 255),   # images - coral red
        (255, 209, 102, 255),   # documents - amber
        (6, 214, 160, 255),     # video - teal/green
        (17, 138, 178, 255),    # audio - deep blue
    ]
    dot_r = 62
    gap = 150
    start_x = cx - gap * 1.5
    dot_y = body_top + body_h - dot_r * 0.35
    for i, color in enumerate(dot_colors):
        x = start_x + i * gap
        # thin white ring so dots read clearly against the white folder
        draw.ellipse((x - dot_r - 6, dot_y - dot_r - 6, x + dot_r + 6, dot_y + dot_r + 6), fill=(255, 255, 255, 255))
        draw.ellipse((x - dot_r, dot_y - dot_r, x + dot_r, dot_y + dot_r), fill=color)

    img = img.convert("RGB")  # no alpha channel allowed in the App Store icon
    img.save(OUT, "PNG")
    print("wrote", OUT, img.size, img.mode)


if __name__ == "__main__":
    main()
