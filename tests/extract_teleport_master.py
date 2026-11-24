#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cut the teleport master sheet (8 directions, 1 row, magenta bg) into game frames.

Input: import/teleport_master_8dir.png - 8 panels in one row, one mage per
panel, cyan portal ring behind the figure and a rune circle under the feet,
on a pinkish-magenta background (not exactly #FF00FF - the model never is).

The sheet-specific problems and how they are solved:

  * the background is a magenta GRADIENT, so a plain chroma key leaks: the
    mask is "magentaness" (min(R,B) - G > 90) FLOOD-FILLED from the panel
    border, so only the background connected to the edge is removed - the
    interior blues (portal, runes) never match the rule anyway;
  * the portal ring may not touch the figure, so "keep largest component"
    would delete it: every component >= 8% of the largest survives instead
    (the faction-art rule against ghost duplicates);
  * the glow fringe is semi-transparent pink: downscale runs in premultiplied
    alpha and the result is binarized at 128 (the city art contract, NEAREST
    rendering), which cuts the fringe instead of smearing it.

Output geometry (the city NPC contract, tests/city_npc_art_smoke.gd):
  canvas 52x64, figure height 58 px, content bottom row 61, pivot cx 26 cy 62.

Sheet panel order = world octants 0..7 (down, down-left, left, up-left, up,
up-right, right, down-right) - the prompt asked for exactly this order.

Magenta recolour: the model painted the rune circle and the hand glyphs PINK
(the same hue family as the backdrop), which reads as a background leftover on
game terrain. Every solid pixel with magentaness > 40 is re-pointed at the
cyan-blue ramp of the portal, keeping its own lightness - the circle stays
readable and stops pretending to be a chroma-key hole.

Usage:
  py tests/extract_teleport_master.py --preview
  py tests/extract_teleport_master.py --build
  py tests/extract_teleport_master.py --check
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
DEFAULT_SRC = REPO / "import" / "teleport_master_8dir.png"
OUT_DIR = REPO / "assets" / "units" / "city_teleport_master" / "t0"
PREVIEW_DIR = REPO / "import" / "teleport_out"

PANELS = 8
MAGENTA_MIN = 90       # min(R,B) - G above this is background-magenta
RECOLOR_MIN = 40       # solid pixels above this are pink content -> re-hued blue
MIN_PART = 0.08        # components smaller than 8% of the largest are debris
CELL_W = 52            # city art contract
CELL_H = 64
FIGURE_H = 58
FEET_ROW = 61
ALPHA_CUT = 128


def _magenta_mask(rgb: np.ndarray) -> np.ndarray:
    r = rgb[..., 0].astype(np.int32)
    g = rgb[..., 1].astype(np.int32)
    b = rgb[..., 2].astype(np.int32)
    return (np.minimum(r, b) - g) > MAGENTA_MIN


def _edge_flood(magenta: np.ndarray) -> np.ndarray:
    """Background = magenta pixels 4-connected to the panel border."""
    h, w = magenta.shape
    bg = np.zeros((h, w), dtype=bool)
    q: deque[tuple[int, int]] = deque()
    for x in range(w):
        for y in (0, h - 1):
            if magenta[y, x] and not bg[y, x]:
                bg[y, x] = True
                q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if magenta[y, x] and not bg[y, x]:
                bg[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
            if 0 <= ny < h and 0 <= nx < w and magenta[ny, nx] and not bg[ny, nx]:
                bg[ny, nx] = True
                q.append((ny, nx))
    return bg


def _keep_big_components(mask: np.ndarray) -> np.ndarray:
    """Drop debris; keep every component >= MIN_PART of the largest one.

    Two-pass CCL on a 2x downsampled grid (the panels are ~250x660, pure
    Python is fine at that size).
    """
    h, w = mask.shape
    sh, sw = h // 2, w // 2
    small = mask[: sh * 2, : sw * 2].reshape(sh, 2, sw, 2).max(axis=(1, 3))
    labels = np.full((sh, sw), -1, dtype=np.int32)
    parent: list[int] = []

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for y in range(sh):
        for x in range(sw):
            if not small[y, x]:
                continue
            up = labels[y - 1, x] if y > 0 else -1
            lf = labels[y, x - 1] if x > 0 else -1
            if up < 0 and lf < 0:
                labels[y, x] = len(parent)
                parent.append(len(parent))
            elif up >= 0 and lf < 0:
                labels[y, x] = up
            elif lf >= 0 and up < 0:
                labels[y, x] = lf
            else:
                labels[y, x] = up
                union(up, lf)
    if not parent:
        return mask
    for y in range(sh):
        for x in range(sw):
            if labels[y, x] >= 0:
                labels[y, x] = find(labels[y, x])
    sizes: dict[int, int] = {}
    for i in range(len(parent)):
        sizes[i] = int((labels == i).sum())
    best = max(sizes.values())
    keep_ids = {i for i, s in sizes.items() if s >= best * MIN_PART}
    keep = np.isin(labels, list(keep_ids))
    # dilate by 1 block so antialiased rim blocks survive
    keep_d = keep.copy()
    keep_d[1:, :] |= keep[:-1, :]
    keep_d[:-1, :] |= keep[1:, :]
    keep_d[:, 1:] |= keep[:, :-1]
    keep_d[:, :-1] |= keep[:, 1:]
    big = np.repeat(np.repeat(keep_d, 2, axis=0), 2, axis=1)
    out = mask & big
    out[sh * 2 :, :] = False
    out[:, sw * 2 :] = False
    return out


def _alpha_of(cell: Image.Image) -> np.ndarray:
    rgb = np.asarray(cell.convert("RGB"))
    solid = _keep_big_components(~_edge_flood(_magenta_mask(rgb)))
    return (solid * 255).astype(np.uint8)


def _de_magenta(rgb: np.ndarray, solid: np.ndarray) -> np.ndarray:
    """Re-hue pink content (rune circle, hand glyphs) to the portal's blue.

    A pixel is "pink content" when it survived the background removal but its
    magentaness is still high. The replacement keeps the pixel's own value
    (max channel) on a cyan-blue ramp, so the drawn shading survives.
    """
    out = rgb.copy()
    r = rgb[..., 0].astype(np.int32)
    g = rgb[..., 1].astype(np.int32)
    b = rgb[..., 2].astype(np.int32)
    pink = solid & ((np.minimum(r, b) - g) > RECOLOR_MIN)
    v = np.maximum(np.maximum(r, g), b).astype(np.float32)
    out[..., 0][pink] = np.clip(v[pink] * 0.30, 0, 255)
    out[..., 1][pink] = np.clip(v[pink] * 0.78, 0, 255)
    out[..., 2][pink] = np.clip(v[pink] * 1.00, 0, 255)
    return out


def _bbox(a: np.ndarray) -> tuple[int, int, int, int] | None:
    ys, xs = np.nonzero(a > 16)
    if ys.size == 0:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def cut_panels(im: Image.Image) -> list[Image.Image]:
    w, h = im.size
    pw = w // PANELS
    return [im.crop((i * pw, 0, (i + 1) * pw, h)) for i in range(PANELS)]


def measure(panels: list[Image.Image]) -> list[tuple[int, int, int, int]]:
    boxes = []
    for i, panel in enumerate(panels):
        box = _bbox(_alpha_of(panel))
        if box is None:
            raise SystemExit(f"panel {i + 1}: empty after background removal")
        boxes.append(box)
    return boxes


def place(panel: Image.Image, box: tuple[int, int, int, int], scale: float) -> Image.Image:
    """Crop one figure, premultiplied downscale, binarized alpha, city canvas."""
    x0, y0, x1, y1 = box
    solid = _alpha_of(panel) > 0
    rgb8 = _de_magenta(np.asarray(panel.convert("RGB")), solid)
    rgb = rgb8.astype(np.float32) / 255.0
    a = (_alpha_of(panel).astype(np.float32) / 255.0)
    fig_rgb = rgb[y0:y1, x0:x1]
    fig_a = a[y0:y1, x0:x1]
    prem = np.dstack([fig_rgb[..., c] * fig_a for c in range(3)] + [fig_a])
    img = Image.fromarray((prem * 255).astype(np.uint8), "RGBA")
    nw = max(1, round(img.width * scale))
    nh = max(1, round(img.height * scale))
    img = img.resize((nw, nh), Image.LANCZOS)
    p = np.asarray(img, dtype=np.float32) / 255.0
    al = p[..., 3:4]
    safe = np.where(al < 1e-3, 1.0, al)
    rgb2 = np.clip(p[..., :3] / safe, 0, 1)
    # city contract: hard alpha edge (the game renders NEAREST)
    a_bin = (p[..., 3] >= ALPHA_CUT / 255.0).astype(np.float32)
    out = np.dstack([rgb2, a_bin])
    img = Image.fromarray((out * 255).astype(np.uint8), "RGBA")

    canvas = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
    cx = (CELL_W - img.width) // 2
    canvas.paste(img, (cx, FEET_ROW - img.height), img)
    return canvas


def _load(src: Path) -> tuple[list[Image.Image], list, float]:
    im = Image.open(src).convert("RGBA")
    panels = cut_panels(im)
    boxes = measure(panels)
    heights = [b[3] - b[1] for b in boxes]
    scale = FIGURE_H / max(heights)
    return panels, boxes, scale


def run(src: Path) -> dict:
    panels, boxes, scale = _load(src)
    frames = [place(p, b, scale) for p, b in zip(panels, boxes)]
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for i, f in enumerate(frames):
        f.save(OUT_DIR / f"sprites-{i + 1:03d}.png")
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGBA", (PANELS * CELL_W * 3, CELL_H * 3), (40, 40, 48, 255))
    for i, f in enumerate(frames):
        big = f.resize((CELL_W * 3, CELL_H * 3), Image.NEAREST)
        sheet.paste(big, (i * CELL_W * 3, 0), big)
    sheet.convert("RGB").save(PREVIEW_DIR / "_contact_sheet.png")
    heights = [b[3] - b[1] for b in boxes]
    return {
        "src": str(src.relative_to(REPO)),
        "panels": PANELS,
        "scale": round(scale, 4),
        "figure_h_px": [round(h * scale, 1) for h in heights],
        "out": str(OUT_DIR.relative_to(REPO)),
    }


def check() -> int:
    bad = 0
    for i in range(1, PANELS + 1):
        p = OUT_DIR / f"sprites-{i:03d}.png"
        if not p.exists():
            print(f"MISSING {p.name}")
            bad += 1
            continue
        f = Image.open(p).convert("RGBA")
        arr = np.asarray(f, dtype=np.int32)
        a = arr[..., 3]
        ys, _ = np.nonzero(a > 0)
        feet = int(ys.max()) if ys.size else -1
        h = int(ys.max() - ys.min() + 1) if ys.size else 0
        # magenta traces: a visible pixel that still looks like the backdrop
        magenta = int((((np.minimum(arr[..., 0], arr[..., 2]) - arr[..., 1]) > 120)
                       & (a > 0)).sum())
        ok = (f.size == (CELL_W, CELL_H) and ys.size > 0 and feet <= FEET_ROW
              and 48 <= h <= FIGURE_H and magenta == 0)
        if not ok:
            bad += 1
        print(f"{p.name} {f.size} h={h} feet={feet} magenta={magenta} "
              f"{'OK' if ok else 'BAD'}")
    print("RESULT: %s teleport master frames" % ("OK" if bad == 0 else "FAIL"))
    return 0 if bad == 0 else 1


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(DEFAULT_SRC))
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    src = Path(args.src)
    if args.preview:
        panels, boxes, scale = _load(src)
        hs = [b[3] - b[1] for b in boxes]
        print(f"panels {len(panels)}, figure heights {min(hs)}..{max(hs)} px")
        print(f"scale -> {scale:.4f}, canvas {CELL_W}x{CELL_H}, feet row {FEET_ROW}")
        return
    if args.build:
        print(json.dumps(run(src), indent=2, ensure_ascii=False))
        return
    if args.check:
        raise SystemExit(check())
    ap.print_help()


if __name__ == "__main__":
    main()
