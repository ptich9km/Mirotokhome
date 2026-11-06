"""Game icon for the window and the Windows .exe.

Composes the icon from art that is already in the project (the inn sprite), so
it stays reproducible and no new assets are needed. Outputs:

  assets/ui/icon.png   256x256, used by project.godot (window icon, Linux/macOS)
  assets/ui/icon.ico   multi-size Windows icon for the export preset

The frame and palette follow scripts/ui_theme.gd (dark plate, gold edge), so the
icon matches the in-game UI.

Run:  py -3 tests/gen_game_icon.py [--check]
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/structures/inn_s1/house-001.png"
PNG_OUT = ROOT / "assets/ui/icon.png"
ICO_OUT = ROOT / "assets/ui/icon.ico"
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]

BG_DEEP = (12, 10, 9)
PANEL_INNER = (36, 26, 18)
PANEL_EDGE = (122, 74, 30)
ACCENT = (255, 196, 77)

SIZE = 256


def gradient_bg(top, bottom):
    img = Image.new("RGBA", (SIZE, SIZE))
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        col = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (SIZE, y)], fill=col + (255,))
    return img


def warm_glow(cx, cy, radius):
    """Soft halo behind the subject, so it does not sit on a flat plate."""
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius], fill=90)
    mask = mask.filter(ImageFilter.GaussianBlur(radius * 0.55))
    glow = Image.new("RGBA", (SIZE, SIZE), PANEL_INNER + (255,))
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    img.paste(glow, (0, 0), mask)
    return img


def add_frame(img):
    d = ImageDraw.Draw(img)
    m = 8
    for i in range(3):
        d.rectangle([m + i, m + i, SIZE - 1 - m - i, SIZE - 1 - m - i],
                    outline=PANEL_EDGE + (255,))
    d.rectangle([m + 4, m + 4, SIZE - 5 - m, SIZE - 5 - m], outline=ACCENT + (170,))
    for x, y in ((m + 6, m + 6), (SIZE - m - 7, m + 6),
                 (m + 6, SIZE - m - 7), (SIZE - m - 7, SIZE - m - 7)):
        d.ellipse([x - 3, y - 3, x + 3, y + 3], fill=ACCENT + (255,))
    return img


def place_subject(canvas, art, box):
    art = art.convert("RGBA")
    bbox = art.getbbox()
    if bbox:
        art = art.crop(bbox)
    scale = min(box / art.width, box / art.height)
    art = art.resize((max(1, int(art.width * scale)),
                      max(1, int(art.height * scale))), Image.NEAREST)

    shadow = Image.new("RGBA", art.size, (0, 0, 0, 0))
    shadow.putalpha(art.getchannel("A").point(lambda a: int(a * 0.55)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(6))

    x = (SIZE - art.width) // 2
    y = (SIZE - art.height) // 2
    canvas.alpha_composite(shadow, (x + 4, y + 6))
    canvas.alpha_composite(art, (x, y))
    return canvas


def compose():
    if not SOURCE.exists():
        raise SystemExit(f"missing sprite: {SOURCE}")
    img = gradient_bg((26, 20, 15), BG_DEEP)
    img.alpha_composite(warm_glow(SIZE / 2, SIZE / 2 - 10, 96))
    img = place_subject(img, Image.open(SOURCE), 200)
    return add_frame(img)


def main():
    icon = compose()
    if "--check" in sys.argv:
        if not PNG_OUT.exists() or not ICO_OUT.exists():
            raise SystemExit("FAIL: icon files are missing")
        have = Image.open(PNG_OUT).convert("RGBA")
        if have.tobytes() != icon.tobytes():
            raise SystemExit("FAIL: assets/ui/icon.png differs from the source art")
        print("RESULT: OK gen_game_icon (png matches, ico present)")
        return

    PNG_OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(PNG_OUT)
    icon.save(ICO_OUT, sizes=[(s, s) for s in ICO_SIZES])
    alpha = icon.getchannel("A")
    filled = sum(count for count, value in alpha.getcolors(maxcolors=256) if value > 0)
    print(f"wrote {PNG_OUT.relative_to(ROOT)} ({icon.width}x{icon.height})")
    print(f"wrote {ICO_OUT.relative_to(ROOT)} ({len(ICO_SIZES)} sizes)")
    print(f"opaque pixels: {filled}/{icon.width * icon.height}")


if __name__ == "__main__":
    main()
