#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Recolour potion icons for the alchemy elixirs.

The alchemy rework adds tactical elixirs. Their art is a recolour of the
approved 64x64 painted potions: one bottle line with a colour per effect is
easier to read in the bag than seven unrelated drawings, and it costs nothing.
Two elixirs reuse an existing drawing outright (wind, fury).

Run:
    python tests/gen_elixir_icons.py --preview
    python tests/gen_elixir_icons.py --build
"""

from __future__ import annotations

import argparse
import colorsys
import os
from PIL import Image

POTIONS = os.path.join("assets", "potions")
PREVIEW = os.path.join("import", "elixir_preview.png")

# Hue in degrees; saturation and value are multipliers of the source pixel.
RECIPES = {
    "elixir_rage.png": {"source": "mana_large.png", "hue": 355.0, "sat": 1.30, "val": 1.05},
    "elixir_stone.png": {"source": "mana_large.png", "hue": 215.0, "sat": 0.30, "val": 0.90},
    "elixir_fire.png": {"source": "mana_large.png", "hue": 20.0, "sat": 1.35, "val": 1.18},
    "elixir_frost.png": {"source": "mana_large.png", "hue": 192.0, "sat": 1.05, "val": 1.20},
    "elixir_mending.png": {"source": "nature_leaf.png", "hue": 75.0, "sat": 1.30, "val": 1.10},
}

# Cork and glass stay as painted: warm brown porcelain is the bottle's "wood".
CORK_HUE = (10.0, 45.0)


def _is_cork(h_deg: float, s: float, v: float) -> bool:
    return CORK_HUE[0] <= h_deg <= CORK_HUE[1] and s >= 0.30 and v <= 0.80


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
            if s < 0.12 or _is_cork(h_deg, s, v):
                out_px[x, y] = (r, g, b, a)
                continue
            ns = min(1.0, s * spec["sat"])
            nv = min(1.0, v * spec["val"])
            r2, g2, b2 = colorsys.hsv_to_rgb(spec["hue"] / 360.0, ns, nv)
            out_px[x, y] = (
                int(round(r2 * 255)),
                int(round(g2 * 255)),
                int(round(b2 * 255)),
                a,
            )
    return out


def build(preview: bool) -> int:
    names = list(RECIPES.keys())
    sources = sorted({spec["source"] for spec in RECIPES.values()})
    columns = max(len(sources), len(names))
    sheet = Image.new("RGBA", (64 * columns, 64 * 2), (0, 0, 0, 255))
    made: list[str] = []
    for index, name in enumerate(names):
        spec = RECIPES[name]
        source_path = os.path.join(POTIONS, spec["source"])
        if not os.path.exists(source_path):
            print("FAIL: no source art:", source_path)
            return 2
        with Image.open(source_path) as source:
            source.load()
            result = recolor(source, spec)
        if preview:
            continue
        result.save(os.path.join(POTIONS, name))
        made.append(name)
    # Preview: every source with its recolour underneath.
    for column, name in enumerate(sources):
        with Image.open(os.path.join(POTIONS, name)) as im:
            sheet.paste(im.convert("RGBA"), (64 * column, 0))
    for column, name in enumerate(names):
        with Image.open(os.path.join(POTIONS, RECIPES[name]["source"])) as src:
            src.load()
            sheet.paste(recolor(src, RECIPES[name]), (64 * column, 64))
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    sheet = sheet.resize((sheet.width * 3, sheet.height * 3), Image.NEAREST)
    sheet.save(PREVIEW)
    print("preview:", PREVIEW.replace(os.sep, "/"))
    if preview:
        print("RESULT: OK (preview only, no files written)")
        return 0
    print("written:", made)
    print("RESULT: OK", len(made), "elixir icons")
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
