#!/usr/bin/env python3
"""Artwork for the itch.io page theme (11.11).

Three files, all generated from assets already in the repository, so nothing is
bought and nothing is hand-drawn:

  theme/bg-tile.png       512x512 seamless background for the theme editor
  theme/favicon-32.png    32x32 favicon (Metadata -> Promo images)
  theme/social-1200x630.png  share card (Metadata -> Promo images, og:image)

The background is a quiet, seamless tile rather than a screenshot: itch repeats
the background image, and a repeated screenshot reads as a bug. The tile uses the
game palette from scripts/ui_theme.gd (BG_DEEP #0C0A09, PANEL_BG #120E0B,
PANEL_EDGE #7A4A1E) and only low-frequency periodic noise, which is seamless by
construction -- random grain would leave a visible seam at the tile edge.

Usage:
  python tests/gen_itch_theme_art.py            # build
  python tests/gen_itch_theme_art.py --check    # verify sizes and seam
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "publish" / "theme"
SHOTS = REPO / "docs" / "publish" / "screenshots"
ICON = REPO / "assets" / "ui" / "icon.png"
FONT_BOLD = REPO / "assets" / "fonts" / "Philosopher-Bold.ttf"
FONT_BODY = REPO / "assets" / "fonts" / "PT_Sans-Web-Regular.ttf"

BG_DEEP = (0x0C, 0x0A, 0x09)
PANEL_BG = (0x12, 0x0E, 0x0B)
EDGE = (0x7A, 0x4A, 0x1E)
TEXT = (0xF5, 0xE3, 0xB8)

TILE = 512


def bg_tile() -> Image.Image:
    """Seamless dark tile: periodic sine field + a diagonal hatch that divides 512."""
    y, x = np.mgrid[0:TILE, 0:TILE].astype(np.float64)
    u, v = x / TILE, y / TILE

    field = np.zeros((TILE, TILE))
    # Integer frequencies -> exactly periodic over the tile, so edges match.
    for fx, fy, amp, phase in (
        (3, 2, 1.00, 0.0),
        (5, 7, 0.55, 1.7),
        (11, 13, 0.28, 4.1),
        (23, 19, 0.12, 2.6),
    ):
        field += amp * np.sin(2 * np.pi * (fx * u + fy * v) + phase)
    field = (field - field.min()) / (field.max() - field.min())

    # Blend between two palette darks: keeps it a texture, not a picture. The
    # contrast is deliberately low but not invisible -- a tile that reads as flat
    # black is pointless, the BG colour alone already does that.
    lo = np.array(BG_DEEP, dtype=np.float64)
    hi = np.array((38, 26, 17), dtype=np.float64)
    rgb = lo[None, None, :] + (hi - lo)[None, None, :] * (0.18 + 0.82 * field[..., None])

    # Diagonal hatch, period 64 divides 512, so it stays seamless too.
    hatch = (((x + y) % 64) < 1.0).astype(np.float64) * 0.07
    rgb = rgb + hatch[..., None] * np.array(EDGE, dtype=np.float64) * 0.55

    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")


def favicon() -> Image.Image:
    icon = Image.open(ICON).convert("RGBA")
    return icon.resize((32, 32), Image.LANCZOS)


def social_card() -> Image.Image:
    # Combat shot, mirrored for the backdrop. Two reasons: the chat log sits in
    # the bottom-left corner, and the terrain has a hard vertical seam and
    # blocky water patches in the right half (known visual issue, not something
    # to advertise). Mirroring the clean left half removes both -- the join is
    # continuous by construction.
    shot = Image.open(SHOTS / "05_combat.png").convert("RGB")
    left_half = shot.crop((0, 20, 510, 580))
    flip = left_half.transpose(Image.FLIP_LEFT_RIGHT)
    mirror = Image.new("RGB", (left_half.width * 2, left_half.height), BG_DEEP)
    mirror.paste(left_half, (0, 0))
    mirror.paste(flip, (left_half.width, 0))
    shot = mirror

    target = (1200, 630)
    scale = max(target[0] / shot.width, target[1] / shot.height)
    shot = shot.resize((int(shot.width * scale) + 1, int(shot.height * scale) + 1),
                       Image.LANCZOS)
    left = (shot.width - target[0]) // 2
    top = (shot.height - target[1]) // 2
    shot = shot.crop((left, top, left + target[0], top + target[1]))
    shot = shot.filter(ImageFilter.GaussianBlur(1.5))

    card = Image.new("RGB", target, BG_DEEP)
    card.paste(shot, (0, 0))
    shade = Image.new("RGB", target, (8, 6, 5))
    card = Image.blend(card, shade, 0.68)

    draw = ImageDraw.Draw(card, "RGBA")
    # Bottom gradient keeps the subtitle readable without a hard band.
    for i in range(240):
        alpha = int(150 * (i / 240) ** 1.4)
        draw.line([(0, target[1] - 240 + i), (target[0], target[1] - 240 + i)],
                  fill=(6, 5, 4, alpha))
    draw.rectangle([(0, 0), (target[0] - 1, target[1] - 1)],
                   outline=(0x7A, 0x4A, 0x1E, 255), width=3)

    title_font = ImageFont.truetype(str(FONT_BOLD), 104)
    sub_font = ImageFont.truetype(str(FONT_BODY), 34)
    small_font = ImageFont.truetype(str(FONT_BODY), 24)

    title = "Mirotokhome"
    sub = "Procedurally generated sandbox RPG with tactical combat"
    small = "Windows  В·  0.2.0  В·  interface in Russian"

    tw = draw.textlength(title, font=title_font)
    draw.text(((target[0] - tw) / 2, 210), title, font=title_font, fill=TEXT)

    sw = draw.textlength(sub, font=sub_font)
    draw.text(((target[0] - sw) / 2, 350), sub, font=sub_font, fill=(0xE6, 0xD4, 0xA8))

    mw = draw.textlength(small, font=small_font)
    draw.text(((target[0] - mw) / 2, 410), small, font=small_font, fill=(0xA0, 0x8D, 0x72))

    # Thin bronze rule under the title, matching the in-game panel edge.
    draw.rectangle([(target[0] / 2 - 140, 330), (target[0] / 2 + 140, 332)],
                   fill=EDGE)
    return card


def check() -> int:
    bad = 0
    tile = OUT / "bg-tile.png"
    if not tile.exists():
        print("MISSING", tile)
        return 1
    img = np.asarray(Image.open(tile).convert("RGB"), dtype=np.int16)
    if img.shape[:2] != (TILE, TILE):
        print("BAD size", img.shape)
        bad += 1
    # A seamless tile has no jump at the wrap edge; compare the step across the
    # seam with an average interior step.
    seam_x = np.abs(img[:, 0] - img[:, -1]).mean()
    seam_y = np.abs(img[0, :] - img[-1, :]).mean()
    interior = np.abs(np.diff(img, axis=1)).mean()
    if seam_x > interior * 4 + 2 or seam_y > interior * 4 + 2:
        print(f"BAD seam: x={seam_x:.2f} y={seam_y:.2f} interior={interior:.2f}")
        bad += 1
    else:
        print(f"seam ok: x={seam_x:.2f} y={seam_y:.2f} interior={interior:.2f}")

    fav = Image.open(OUT / "favicon-32.png")
    if fav.size != (32, 32):
        print("BAD favicon size", fav.size)
        bad += 1

    card = Image.open(OUT / "social-1200x630.png")
    if card.size != (1200, 630):
        print("BAD card size", card.size)
        bad += 1

    print("RESULT:", "OK itch theme art" if bad == 0 else f"FAIL ({bad})")
    return 0 if bad == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if args.check:
        return check()

    OUT.mkdir(parents=True, exist_ok=True)
    bg_tile().save(OUT / "bg-tile.png")
    favicon().save(OUT / "favicon-32.png")
    social_card().save(OUT / "social-1200x630.png")

    for name in ("bg-tile.png", "favicon-32.png", "social-1200x630.png"):
        p = OUT / name
        with Image.open(p) as im:
            print(f"{name}: {im.size[0]}x{im.size[1]} {p.stat().st_size // 1024} KB")
    return check()


if __name__ == "__main__":
    sys.exit(main())
