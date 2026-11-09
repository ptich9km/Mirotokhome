#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Recolour herb icons for the high-tier herbs (tier 3-4).

The alchemy rework puts three herbs in every zone tier. Eight icons already
exist; the four new ones are recolours of them, so the step costs nothing and
needs no network. When KodikRouter is reachable again the animated AI strips
replace these files one by one - the game reads the file name from
`herbs_db.json`, so nothing else changes.

Recolouring keeps the painted look: only hue/saturation/value of the leaves
and the accent parts move, the brown soil and the alpha stay as they are.

Run:
    python tests/gen_herb_tier_icons.py --preview
    python tests/gen_herb_tier_icons.py --build
"""

from __future__ import annotations

import argparse
import colorsys
import os
from PIL import Image

HERBALISM = os.path.join("assets", "professions", "herbalism")
PREVIEW = os.path.join("import", "herb_tier_preview.png")

# target -> (source file, leaf hue/sat/val, accent hue/sat/val, soil twEAK)
# Hue is in degrees, saturation and value are multipliers of the source pixel.
RECIPES = {
    "glowmoss.png": {
        "source": "mint.png",
        "leaf": (78.0, 1.35, 1.10),      # bright yellow-green luminescence
        "accent": (66.0, 1.20, 1.15),
        "soil": (1.00, 0.95),
    },
    "shadow_fern.png": {
        "source": "broad_leaf.png",
        "leaf": (272.0, 0.75, 0.62),     # deep violet, dim
        "accent": (285.0, 0.90, 0.70),
        "soil": (0.80, 0.55),
    },
    "astral_lotus.png": {
        "source": "white_flower.png",
        "leaf": (176.0, 0.85, 0.95),     # teal leaves
        "accent": (268.0, 0.75, 1.25),   # pale astral petals
        "soil": (0.85, 0.80),
    },
    "ember_root.png": {
        "source": "red_berry.png",
        "leaf": (95.0, 0.80, 0.70),      # scorched olive leaves
        "accent": (24.0, 1.45, 1.25),    # ember-orange berries
        "soil": (0.95, 0.85),
    },
}

LEAF_RANGE = (60.0, 175.0)
SOIL_HUE = (8.0, 45.0)
SOIL_MAX_VALUE = 0.62


def _is_soil(h_deg: float, s: float, v: float) -> bool:
    return SOIL_HUE[0] <= h_deg <= SOIL_HUE[1] and v <= SOIL_MAX_VALUE and s >= 0.15


def _shift(rgb, target) -> tuple[int, int, int]:
    r, g, b = (channel / 255.0 for channel in rgb)
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    hue, sat_mul, val_mul = target
    s = min(1.0, s * sat_mul)
    v = min(1.0, v * val_mul)
    r, g, b = colorsys.hsv_to_rgb(hue / 360.0, s, v)
    return (
        int(round(r * 255)),
        int(round(g * 255)),
        int(round(b * 255)),
    )


def recolor(source: Image.Image, spec: dict) -> Image.Image:
    src = source.convert("RGBA")
    out = Image.new("RGBA", src.size, (0, 0, 0, 0))
    src_px = src.load()
    out_px = out.load()
    width, height = src.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = src_px[x, y]
            if a == 0:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            h_deg = h * 360.0
            if s < 0.10:
                out_px[x, y] = (r, g, b, a)          # neutral highlight
                continue
            if _is_soil(h_deg, s, v):
                sat_mul, val_mul = spec["soil"]
                out_px[x, y] = _shift((r, g, b), (h_deg, sat_mul, val_mul)) + (a,)
                continue
            target = spec["leaf"] if LEAF_RANGE[0] <= h_deg <= LEAF_RANGE[1] else spec["accent"]
            out_px[x, y] = _shift((r, g, b), target) + (a,)
    return out


def build(preview: bool) -> int:
    names = list(RECIPES.keys())
    sheet = Image.new("RGBA", (32 * (len(names) + 1), 32 * 2), (0, 0, 0, 255))
    made: list[str] = []
    for index, name in enumerate(names):
        spec = RECIPES[name]
        source_path = os.path.join(HERBALISM, spec["source"])
        if not os.path.exists(source_path):
            print("FAIL: no source art:", source_path)
            return 2
        with Image.open(source_path) as source:
            source.load()
            result = recolor(source, spec)
            sheet.paste(source.convert("RGBA"), (32 * index, 0))
            sheet.paste(result, (32 * index, 32))
        if preview:
            continue
        target_path = os.path.join(HERBALISM, name)
        result.save(target_path)
        made.append(name)
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    sheet = sheet.resize((sheet.width * 4, sheet.height * 4), Image.NEAREST)
    sheet.save(PREVIEW)
    print("preview:", PREVIEW.replace(os.sep, "/"))
    if preview:
        print("RESULT: OK (preview only, no files written)")
        return 0
    print("written:", made)
    print("RESULT: OK", len(made), "herb icons")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    if not args.preview and not args.build:
        parser.error("choose --preview or --build")
    return build(args.preview)


if __name__ == "__main__":
    raise SystemExit(main())
