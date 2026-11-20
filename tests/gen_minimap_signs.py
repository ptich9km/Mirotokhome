#!/usr/bin/env python3
"""Minimap signs for the mission types: 16x16 flat glyphs, one per sheet slug.

Why a separate set: the mission sheets are 64x64 painterly frames, and downscaled
to a minimap sign they turn into a dark smudge - the chest reads as a brown
rectangle, the dragon eye as a red blob (measured 20.11). A minimap is read at a
glance on coloured terrain, so it needs flat silhouettes and two or three colours,
not a shrunk painting.

Output: assets/quests/missions/minimap/<slug>.png - RGBA 16x16 with a 1 px dark
outline around the silhouette, so the sign survives on grass, sand, road and water.

Run:
  python tests/gen_minimap_signs.py --preview   # contact sheet, nothing written
  python tests/gen_minimap_signs.py --build
  python tests/gen_minimap_signs.py --check
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "assets" / "quests" / "missions" / "minimap"
PREVIEW = REPO / "import" / "Missions" / "_minimap_preview.png"

SIZE = 16
OUTLINE = (10, 10, 16, 255)

EDGE = (10, 10, 16, 255)
STEEL = (156, 166, 180, 255)
STEEL_D = (98, 108, 124, 255)
GOLD = (242, 190, 62, 255)
GOLD_D = (176, 122, 28, 255)
WOOD = (150, 96, 54, 255)
WOOD_D = (100, 62, 34, 255)
WHITE = (246, 246, 238, 255)
YELLOW = (248, 214, 84, 255)
GREEN = (96, 170, 88, 255)
GREEN_D = (58, 120, 60, 255)
RED = (208, 66, 54, 255)
RED_D = (140, 34, 30, 255)
SKIN = (228, 186, 146, 255)
CLOTH = (122, 112, 152, 255)
BRICK = (192, 82, 62, 255)
BRICK_D = (140, 54, 40, 255)


def canvas() -> np.ndarray:
    return np.zeros((SIZE, SIZE, 4), np.uint8)


def rect(img: np.ndarray, x0: int, y0: int, x1: int, y1: int, color) -> None:
    """Filled rectangle, inclusive coordinates."""
    img[max(0, y0):y1 + 1, max(0, x0):x1 + 1] = color


def dot(img: np.ndarray, x: int, y: int, color) -> None:
    if 0 <= x < SIZE and 0 <= y < SIZE:
        img[y, x] = color


def disc(img: np.ndarray, cx: float, cy: float, r: float, color) -> None:
    ys, xs = np.mgrid[0:SIZE, 0:SIZE]
    mask = (xs - cx) ** 2 + (ys - cy) ** 2 <= r * r
    img[mask] = color


def thick_line(img: np.ndarray, x0: int, y0: int, x1: int, y1: int, color,
               width: int = 1) -> None:
    steps = max(abs(x1 - x0), abs(y1 - y0)) * 2 + 1
    for i in range(steps + 1):
        t = i / steps
        x = int(round(x0 + (x1 - x0) * t))
        y = int(round(y0 + (y1 - y0) * t))
        for oy in range(width):
            for ox in range(width):
                dot(img, x + ox, y + oy, color)


def add_outline(img: np.ndarray) -> np.ndarray:
    """1 px dark rim around the silhouette (8-neighbourhood)."""
    solid = img[..., 3] > 0
    pad = np.pad(solid, 1)
    ring = np.zeros_like(pad)
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            ring |= np.roll(np.roll(pad, oy, axis=0), ox, axis=1)
    ring = ring[1:-1, 1:-1] & ~solid
    out = img.copy()
    out[ring] = EDGE
    return out


# --- One glyph per slug -------------------------------------------------------

def sign_find_items(img: np.ndarray) -> None:
    """Chest: lid, body, gold band."""
    rect(img, 3, 6, 12, 12, WOOD)
    rect(img, 3, 4, 12, 5, WOOD_D)
    rect(img, 3, 8, 12, 8, WOOD_D)
    rect(img, 7, 6, 8, 12, GOLD_D)
    rect(img, 7, 6, 8, 6, GOLD)
    rect(img, 6, 7, 9, 9, GOLD)
    dot(img, 7, 8, WOOD_D)
    dot(img, 8, 8, WOOD_D)


def sign_destroy(img: np.ndarray) -> None:
    """Two blades crossed."""
    thick_line(img, 3, 12, 12, 3, STEEL)
    thick_line(img, 12, 12, 3, 3, STEEL_D)
    thick_line(img, 2, 11, 4, 13, GOLD_D)
    thick_line(img, 13, 11, 11, 13, GOLD_D)
    dot(img, 3, 3, GOLD)
    dot(img, 12, 3, GOLD_D)


def sign_alchemy_gather(img: np.ndarray) -> None:
    """Daisy: petals, heart, stem."""
    for ox, oy in ((-2, 0), (2, 0), (0, -2), (0, 2), (-1, -1), (1, -1), (-1, 1), (1, 1)):
        dot(img, 8 + ox, 6 + oy, WHITE)
    dot(img, 8, 6, YELLOW)
    rect(img, 7, 8, 7, 12, GREEN_D)
    dot(img, 6, 11, GREEN)
    dot(img, 5, 11, GREEN)
    dot(img, 6, 12, GREEN_D)


def sign_escort(img: np.ndarray) -> None:
    """Two figures walking, hands linked."""
    disc(img, 5, 4, 1.4, SKIN)
    disc(img, 10, 4, 1.4, SKIN)
    rect(img, 4, 6, 6, 11, CLOTH)
    rect(img, 9, 6, 11, 11, WOOD)
    rect(img, 4, 12, 4, 13, WOOD_D)
    rect(img, 6, 12, 6, 13, WOOD_D)
    rect(img, 9, 12, 9, 13, WOOD_D)
    rect(img, 11, 12, 11, 13, WOOD_D)
    rect(img, 7, 8, 8, 8, SKIN)


def sign_build_repair(img: np.ndarray) -> None:
    """Brick wall under a trowel."""
    rect(img, 2, 8, 13, 13, BRICK_D)
    rect(img, 2, 8, 6, 10, BRICK)
    rect(img, 4, 8, 4, 10, BRICK_D)
    rect(img, 7, 11, 12, 13, BRICK)
    rect(img, 10, 11, 10, 13, BRICK_D)
    thick_line(img, 9, 3, 13, 6, STEEL)
    thick_line(img, 8, 4, 8, 6, WOOD_D)


def sign_caravan(img: np.ndarray) -> None:
    """Wagon with ingots and two wheels."""
    rect(img, 2, 6, 12, 10, WOOD)
    rect(img, 2, 6, 12, 6, WOOD_D)
    rect(img, 2, 10, 12, 10, WOOD_D)
    rect(img, 4, 4, 7, 5, GOLD)
    rect(img, 8, 5, 10, 5, GOLD_D)
    dot(img, 4, 4, YELLOW)
    disc(img, 4, 12, 1.8, STEEL_D)
    disc(img, 4, 12, 0.7, WOOD_D)
    disc(img, 10, 12, 1.8, STEEL_D)
    disc(img, 10, 12, 0.7, WOOD_D)


def sign_boss_kill(img: np.ndarray) -> None:
    """Dragon eye with a slit pupil."""
    disc(img, 8, 7, 4.6, RED_D)
    disc(img, 8, 7, 3.4, RED)
    rect(img, 7, 3, 8, 11, GOLD_D)
    rect(img, 7, 5, 8, 9, YELLOW)
    dot(img, 8, 7, RED_D)
    thick_line(img, 12, 8, 14, 12, STEEL)


def sign_faction_war(img: np.ndarray) -> None:
    """Shield with a stone flying into it."""
    rect(img, 4, 5, 11, 9, STEEL)
    rect(img, 5, 10, 10, 10, STEEL)
    rect(img, 6, 11, 9, 11, STEEL_D)
    rect(img, 7, 12, 8, 12, STEEL_D)
    rect(img, 7, 5, 8, 11, STEEL_D)
    rect(img, 4, 5, 11, 5, STEEL_D)
    # Stone on its way in, with a spark where it lands.
    disc(img, 2.5, 3.0, 1.4, (168, 168, 168, 255))
    dot(img, 4, 2, (206, 206, 206, 255))
    dot(img, 9, 8, YELLOW)
    dot(img, 10, 8, GOLD_D)


def sign_story_chain(img: np.ndarray) -> None:
    """Golden key: bow, shaft, two teeth."""
    disc(img, 4.5, 5.5, 2.6, GOLD)
    disc(img, 4.5, 5.5, 1.0, (0, 0, 0, 0))
    thick_line(img, 6, 7, 11, 12, GOLD)
    rect(img, 10, 12, 11, 13, GOLD_D)
    rect(img, 12, 10, 13, 11, GOLD_D)
    dot(img, 5, 4, YELLOW)


SIGNS = {
    "find_items": sign_find_items,
    "destroy": sign_destroy,
    "alchemy_gather": sign_alchemy_gather,
    "escort": sign_escort,
    "build_repair": sign_build_repair,
    "caravan": sign_caravan,
    "boss_kill": sign_boss_kill,
    "faction_war": sign_faction_war,
    "story_chain": sign_story_chain,
}


def build(slug: str) -> Image.Image:
    img = canvas()
    SIGNS[slug](img)
    # The key's bow is a hole: keep it transparent instead of painting it.
    img[img[..., 3] == 0] = (0, 0, 0, 0)
    return Image.fromarray(add_outline(img), "RGBA")


def preview(images: dict[str, Image.Image]) -> None:
    zoom = 6
    pad = 6
    cols = 5
    rows = (len(images) + cols - 1) // cols
    w = cols * (SIZE * zoom + pad) + pad
    h = rows * (SIZE * zoom + pad) + pad
    sheet = Image.new("RGBA", (w, h), (24, 21, 18, 255))
    bgs = [(96, 160, 96), (216, 186, 96), (86, 120, 190), (120, 104, 80)]
    for i, (slug, im) in enumerate(images.items()):
        x = pad + (i % cols) * (SIZE * zoom + pad)
        y = pad + (i // cols) * (SIZE * zoom + pad)
        bg = Image.new("RGBA", (SIZE, SIZE), bgs[i % len(bgs)] + (255,))
        bg.alpha_composite(im)
        sheet.paste(bg.resize((SIZE * zoom, SIZE * zoom), Image.NEAREST), (x, y))
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(PREVIEW)
    print(f"preview: {PREVIEW.relative_to(REPO)}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--preview", action="store_true", help="contact sheet only")
    ap.add_argument("--build", action="store_true", help="write the signs")
    ap.add_argument("--check", action="store_true", help="verify the written signs")
    args = ap.parse_args()
    images = {slug: build(slug) for slug in SIGNS}
    if args.check:
        bad = []
        for slug, im in images.items():
            path = OUT_DIR / f"{slug}.png"
            if not path.exists():
                bad.append(f"{slug}: missing {path.name}")
                continue
            on_disk = Image.open(path)
            if on_disk.size != (SIZE, SIZE):
                bad.append(f"{slug}: {on_disk.size} instead of {SIZE}x{SIZE}")
                continue
            if not np.array_equal(np.array(on_disk.convert("RGBA")), np.array(im)):
                bad.append(f"{slug}: differs from the generator")
        for line in bad:
            print("FAIL:", line)
        print("RESULT: " + ("OK" if not bad else f"FAIL ({len(bad)})"))
        return 0 if not bad else 1
    if args.preview or not args.build:
        preview(images)
        print("RESULT: OK (preview, nothing written)")
        return 0
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for slug, im in images.items():
        im.save(OUT_DIR / f"{slug}.png")
    preview(images)
    print(f"RESULT: OK ({len(images)} signs in {OUT_DIR.relative_to(REPO)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
