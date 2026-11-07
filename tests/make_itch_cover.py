"""Builds the 630x500 itch cover from a gameplay shot.

itch crops nothing: the cover is uploaded as-is and shown at 630x500 in lists,
so the title must be readable at thumbnail size. The screenshot is scaled to
fill the box, darkened top and bottom (the HUD lives there and would fight with
the text), then the title goes on in the game's own accent colour.

Run:  py -3 tests/make_itch_cover.py
      py -3 tests/make_itch_cover.py --shot docs/publish/screenshots/01_world.png
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
COVER_W, COVER_H = 630, 500

# Same hues as scripts/ui_theme.gd: the cover must not invent a palette.
ACCENT = (255, 196, 77)
TEXT = (245, 227, 184)


def load_font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(ROOT / "assets/fonts" / name), size)


def build(shot: Path, out: Path, crop_w: int, cx: int, cy: int) -> None:
    src = Image.open(shot).convert("RGB")
    # Crop a window around the hero instead of shrinking the whole 1280x800
    # frame: at full width the character is a speck and the cover reads as a map.
    crop_h = int(round(crop_w * COVER_H / COVER_W))
    left = max(0, min(src.width - crop_w, cx - crop_w // 2))
    top = max(0, min(src.height - crop_h, cy - crop_h // 2))
    cover = src.crop((left, top, left + crop_w, top + crop_h))
    cover = cover.resize((COVER_W, COVER_H), Image.LANCZOS)

    # Bottom scrim: a hard band looks like a template, a blurred gradient reads
    # as lighting and keeps the terrain visible behind the text. It also has to
    # swallow the combat log in the corner, or the cover looks like a screenshot
    # with text dropped on top.
    scrim = Image.new("L", (1, COVER_H), 0)
    for y in range(COVER_H):
        t = max(0.0, (y - COVER_H * 0.40) / (COVER_H * 0.60))
        scrim.putpixel((0, y), int(248 * t ** 1.5))
    scrim = scrim.resize((COVER_W, COVER_H))
    cover = Image.composite(Image.new("RGB", cover.size, (6, 5, 4)), cover, scrim)

    top = Image.new("L", (1, COVER_H), 0)
    for y in range(COVER_H):
        t = max(0.0, (COVER_H * 0.30 - y) / (COVER_H * 0.30))
        top.putpixel((0, y), int(190 * t ** 1.3))
    cover = Image.composite(Image.new("RGB", cover.size, (6, 5, 4)), cover,
                            top.resize((COVER_W, COVER_H)))

    # Sooner or later the minimap, the gold counter or a tooltip lands in a
    # corner; a soft vignette hides them without a visible rectangle.
    vig = Image.new("L", (COVER_W, COVER_H), 0)
    vdraw = ImageDraw.Draw(vig)
    for i in range(14):
        inset = i * 9
        vdraw.rectangle([inset, inset, COVER_W - inset, COVER_H - inset],
                        outline=int(8 + i * 1.5))
    vig = vig.filter(ImageFilter.GaussianBlur(28))
    cover = Image.composite(Image.new("RGB", cover.size, (6, 5, 4)), cover, vig)

    draw = ImageDraw.Draw(cover)

    title = "MIROTOKHOME"
    font = load_font("Philosopher-Bold.ttf", 62)
    box = draw.textbbox((0, 0), title, font=font)
    tw = box[2] - box[0]
    x = (COVER_W - tw) // 2
    y = COVER_H - 148
    # A soft shadow: gold on bright sand is unreadable without one.
    draw.text((x + 2, y + 3), title, font=font, fill=(10, 8, 6))
    draw.text((x, y), title, font=font, fill=ACCENT)

    rule_y = y + (box[3] - box[1]) + 22
    draw.line([(COVER_W // 2 - 84, rule_y), (COVER_W // 2 + 84, rule_y)],
              fill=(150, 99, 40), width=2)

    tag = "песочница · тактическая RPG"
    tag_font = load_font("PT_Sans-Web-Regular.ttf", 20)
    tbox = draw.textbbox((0, 0), tag, font=tag_font)
    draw.text(((COVER_W - (tbox[2] - tbox[0])) // 2, rule_y + 12), tag,
              font=tag_font, fill=TEXT)

    out.parent.mkdir(parents=True, exist_ok=True)
    cover.save(out, optimize=True)
    print(f"{out}: {cover.size[0]}x{cover.size[1]}, "
          f"{out.stat().st_size / 1024:.0f} KB")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shot", default="docs/publish/screenshots/01_world.png")
    ap.add_argument("--out", default="docs/publish/cover.png")
    ap.add_argument("--crop", type=int, default=840, help="source crop width")
    ap.add_argument("--cx", type=int, default=640, help="crop centre x in source")
    ap.add_argument("--cy", type=int, default=400, help="crop centre y in source")
    args = ap.parse_args()
    build(ROOT / args.shot, ROOT / args.out, args.crop, args.cx, args.cy)


if __name__ == "__main__":
    main()
