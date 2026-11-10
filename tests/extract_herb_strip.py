#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cut an AI herb strip into 32x32 animation frames.

Input: one sheet from `gen_herb_strip.py` - four poses of the same plant in a
row on flat magenta. Output: `<slug>_frame00..03.png` next to the still icon
(`assets/professions/herbalism/`), which is exactly what `HerbNode` looks for.

Two details decide whether the loop looks alive or broken:

  * ONE scale for all four frames. Scaling each frame to its own height makes
    the plant "breathe" in size - the eye reads that as a glitch, not as wind.
  * the ROOT is the anchor, not the figure box. A swaying plant changes width,
    so centring by the bounding box slides it sideways; centring by the soil
    clump keeps it planted.

The still icon is never overwritten: it stays the inventory picture.

Run:
    python tests/extract_herb_strip.py --only green_leaf --preview
    python tests/extract_herb_strip.py --only green_leaf --build
    python tests/extract_herb_strip.py --all --build
    python tests/extract_herb_strip.py --check
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_hero_strip import components, preflight  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "import" / "herb_strips"
DST = REPO / "assets" / "professions" / "herbalism"
PREVIEW = REPO / "import" / "herb_strips" / "_preview.png"

## Paint dust between the panels is 1-8 px tall, a real plant is ~350 px: a
## short run is not a figure (kept in sync with gen_herb_strip.py).
MIN_FIGURE_H = 40

OUT = 32            # the icon size the map and the inventory use
CONTENT_W = 27      # max plant width inside 32 px
CONTENT_H = 26      # max plant height inside 32 px
GROUND_Y = 29       # the bottom row of the soil: every plant stands on it
ROOT_BAND = 0.22    # the lowest 22 % of the figure is the soil clump

FRAMES = 4


def _magenta_alpha(a: np.ndarray) -> np.ndarray:
    """1.0 for the plant, 0.0 for the flat magenta background.

    The old rule was two colour tests, and its second one - "dark and redder
    than green" - was a violet detector: it deleted lavender spikes, the
    shadow fern and the ember leaves, leaving grey stems (measured on the QC
    sheet 11.11). Now the sheet is normalized to pure magenta by the
    generator, so the background is found geometrically: magenta-ish pixels
    CONNECTED TO THE EDGE, plus enclosed holes of near-pure magenta between
    leaves. A plant colour may be any hue and still survive.
    """
    from collections import deque

    h, w = a.shape[:2]
    corners = np.concatenate([a[:24, :24].reshape(-1, 3), a[:24, -24:].reshape(-1, 3),
                              a[-24:, :24].reshape(-1, 3), a[-24:, -24:].reshape(-1, 3)])
    bg = np.median(corners.astype(np.float32), axis=0)
    close = np.abs(a - bg).max(axis=2) <= 110
    seen = np.zeros((h, w), bool)
    queue: deque = deque()
    for x in range(w):
        for y in (0, h - 1):
            if close[y, x] and not seen[y, x]:
                seen[y, x] = True
                queue.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if close[y, x] and not seen[y, x]:
                seen[y, x] = True
                queue.append((y, x))
    while queue:
        y, x = queue.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and close[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                queue.append((ny, nx))
    ## Enclosed gaps keep the exact background colour and no plant is that
    ## colour, so they are safe to drop even when the flood fill cannot reach.
    hole = np.abs(a - bg).max(axis=2) <= 45
    ## Bright magenta survives around the soil as a painted halo; it is not
    ## always reachable from the edge (the root ball can enclose it), and at
    ## 32 px it reads as a pink stain. "Magenta-ness" is min(R,B) - G: on the
    ## real sheets the halo scores 117, a lavender spike 60, a shadow-fern
    ## frond 40, a red berry 0 - so the threshold cleans the halo and keeps
    ## every plant colour.
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    pink = np.minimum(r, b)
    fringe = (g < 110) & (pink > 140) & ((pink - g) > 90)
    bg_mask = seen | hole | fringe
    alpha = np.where(bg_mask, 0.0, 1.0)
    ## The dark magenta of the contact shadow has the same colour family as a
    ## lavender spike, so colour alone cannot separate them - the POSITION can:
    ## the shadow lives near the soil, the flowers sit on top. The violet rule
    ## therefore applies only to the lower part of the figures.
    rows = np.where(alpha.max(axis=1) > 0)[0]
    if rows.size:
        top = int(rows.min())
        bottom = int(rows.max())
        cut = top + int((bottom - top + 1) * 0.45)
        band = np.zeros_like(alpha)
        band[cut:] = 1.0
        violet = (g < 120) & (g < b - 25) & ((r - g) > 55)
        alpha = np.where((band > 0) & violet, 0.0, alpha)
    return alpha


def _boxes(alpha: np.ndarray) -> list[tuple[int, int, int, int]]:
    """Figure boxes left to right, components merged when they overlap in x.

    `components()` yields (ymin, ymax, xmin, xmax) for pieces of a figure - a
    leaf can be a separate piece, so they are merged by their x span.
    """
    found = components((alpha > 0.5).astype(np.uint8))
    boxes = []
    for ymin, ymax, xmin, xmax in found:
        boxes.append([int(xmin), int(ymin), int(xmax) + 1, int(ymax) + 1])
    if not boxes:
        return []
    boxes.sort(key=lambda b: b[0])
    merged = [boxes[0]]
    for box in boxes[1:]:
        last = merged[-1]
        if box[0] <= last[2] + 6:      # a leaf detached from the same plant
            last[2] = max(last[2], box[2])
            last[1] = min(last[1], box[1])
            last[3] = max(last[3], box[3])
        else:
            merged.append(box)
    return [tuple(b) for b in merged]


def _fallback_columns(alpha: np.ndarray) -> list[tuple[int, int, int, int]]:
    """Equal columns, trimmed to the content inside each."""
    h, w = alpha.shape
    step = w // FRAMES
    out = []
    for index in range(FRAMES):
        x0 = index * step
        x1 = w if index == FRAMES - 1 else (index + 1) * step
        part = alpha[:, x0:x1] > 0.5
        if not part.any():
            out.append((x0, 0, x1, h))
            continue
        ys, xs = np.where(part)
        out.append((x0 + int(xs.min()), int(ys.min()),
                    x0 + int(xs.max()) + 1, int(ys.max()) + 1))
    return out


def _figure_rgba(rgb: np.ndarray, alpha: np.ndarray,
                 box: tuple[int, int, int, int], pad: int = 2) -> Image.Image:
    h, w = alpha.shape
    x0 = max(0, box[0] - pad)
    y0 = max(0, box[1] - pad)
    x1 = min(w, box[2] + pad)
    y1 = min(h, box[3] + pad)
    crop_rgb = rgb[y0:y1, x0:x1].astype(np.uint8)
    crop_a = alpha[y0:y1, x0:x1]
    rgba = np.dstack([crop_rgb, (crop_a * 255).round().astype(np.uint8)])
    return Image.fromarray(rgba, "RGBA")


def _root_x(img: Image.Image) -> float:
    """Horizontal centre of the soil clump (the lowest band of the figure)."""
    arr = np.array(img)
    mask = arr[..., 3] > 40
    if not mask.any():
        return img.width / 2.0
    ys, xs = np.where(mask)
    bottom = int(ys.max())
    top = int(ys.min())
    band_top = bottom - max(2, int((bottom - top + 1) * ROOT_BAND))
    band = mask[band_top:bottom + 1]
    ys2, xs2 = np.where(band)
    if len(xs2) == 0:
        return float(xs.mean())
    return float(xs2.mean())


def _resize_premultiplied(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Downscale in premultiplied alpha, then un-premultiply.

    A straight RGBA resize mixes the RGB of fully transparent pixels into the
    plant, and those pixels still carry MAGENTA from the sheet: the frames came
    out muddy/olive with a pink bias (measured on tall_grass, 11.11 - 350 px
    sheet pixels squeezed into 24 px). Premultiplying makes transparent pixels
    contribute nothing.
    """
    arr = np.array(img).astype(np.float32)
    alpha = arr[..., 3:4] / 255.0
    premul = np.concatenate([arr[..., :3] * alpha, arr[..., 3:4]], axis=2)
    small = np.array(
        Image.fromarray(np.clip(premul, 0, 255).astype(np.uint8), "RGBA")
        .resize(size, Image.Resampling.LANCZOS)
    ).astype(np.float32)
    a = small[..., 3:4] / 255.0
    rgb = np.where(a > 0.002, small[..., :3] / np.maximum(a, 1e-3), 0.0)
    out = np.concatenate([np.clip(rgb, 0, 255), small[..., 3:4]], axis=2)
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def build(slug: str, dry_run: bool) -> bool:
    src = SRC / f"{slug}.png"
    if not src.exists():
        print(f"FAIL {slug}: no sheet {src}")
        return False
    ok, report = preflight(str(src), expect=FRAMES, min_gap=40, min_ratio=0.0,
                           min_figure_h=MIN_FIGURE_H)
    if not ok:
        print(report)
        print(f"FAIL {slug}: preflight rejected the sheet")
        return False

    rgb = np.array(Image.open(src).convert("RGB")).astype(np.int32)
    alpha = _magenta_alpha(rgb)
    boxes = _boxes(alpha)
    if len(boxes) != FRAMES:
        print(f"note {slug}: {len(boxes)} figure(s) found, splitting by columns")
        boxes = _fallback_columns(alpha)
    if len(boxes) != FRAMES:
        print(f"FAIL {slug}: cannot find {FRAMES} figures")
        return False

    figures = [_figure_rgba(rgb, alpha, box) for box in boxes]
    max_w = max(f.width for f in figures)
    max_h = max(f.height for f in figures)
    scale = min(CONTENT_W / max_w, CONTENT_H / max_h)
    if scale > 1.0:
        scale = min(scale, 1.0) * 0.999  # never invent detail
    sizes = []
    frames = []
    for index, fig in enumerate(figures):
        new_w = max(1, int(round(fig.width * scale)))
        new_h = max(1, int(round(fig.height * scale)))
        resized = _resize_premultiplied(fig, (new_w, new_h))
        root = _root_x(fig) * scale
        canvas = Image.new("RGBA", (OUT, OUT), (0, 0, 0, 0))
        x = int(round(OUT / 2.0 - root))
        x = max(-new_w + 2, min(OUT - 2, x))
        y = GROUND_Y - new_h + 1
        canvas.alpha_composite(resized, (x, y))
        frames.append(canvas)
        sizes.append((new_w, new_h))
    if dry_run:
        _contact_sheet(slug, frames, preview_only=True)
        width, height = sizes[0]
        print(f"{slug}: {FRAMES} frames, common scale {scale:.3f}, "
              f"content ~{width}x{height} (preview only, nothing written)")
        return True
    for index, canvas in enumerate(frames):
        canvas.save(DST / f"{slug}_frame{index:02d}.png")

    (DST / f"{slug}_entry.json").write_text(json.dumps({
        "slug": slug,
        "frames": FRAMES,
        "size": [OUT, OUT],
        "scale": round(scale, 3),
        "ground_y": GROUND_Y,
        "source": f"import/herb_strips/{slug}.png",
    }, indent=2, ensure_ascii=False), encoding="utf-8")
    _contact_sheet(slug, frames)
    print(f"OK {slug}: {FRAMES} frames x {OUT}x{OUT}, scale {scale:.3f}")
    return True


def _contact_sheet(slug: str, frames: list[Image.Image],
                   preview_only: bool = False) -> None:
    zoom = 4
    sheet = Image.new("RGBA", (OUT * zoom * len(frames), OUT * zoom), (26, 20, 16, 255))
    for index, frame in enumerate(frames):
        big = frame.resize((OUT * zoom, OUT * zoom), Image.Resampling.NEAREST)
        sheet.alpha_composite(big, (index * OUT * zoom, 0))
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    target = PREVIEW
    if preview_only:
        target = PREVIEW.with_name(f"_preview_{slug}.png")
    sheet.save(target)
    print(f"preview: {target.relative_to(REPO)} ({slug})")


def check() -> int:
    """Frames that already exist must be valid and consistent."""
    problems = []
    sheets = sorted(p.stem for p in SRC.glob("*.png") if not p.stem.startswith("_"))
    if not sheets:
        print("no sheets in import/herb_strips - nothing to check")
    for slug in sheets:
        frames = sorted(DST.glob(f"{slug}_frame*.png"))
        if not frames:
            continue
        if len(frames) != FRAMES:
            problems.append(f"{slug}: {len(frames)} frames instead of {FRAMES}")
            continue
        heights = []
        for path in frames:
            image = Image.open(path)
            if image.size != (OUT, OUT):
                problems.append(f"{path.name}: {image.size} instead of {OUT}x{OUT}")
                continue
            arr = np.array(image.convert("RGBA"))
            mask = arr[..., 3] > 40
            if not mask.any():
                problems.append(f"{path.name}: empty frame")
                continue
            ys, _ = np.where(mask)
            heights.append(int(ys.max() - ys.min() + 1))
        if heights and (max(heights) - min(heights)) > 4:
            problems.append(f"{slug}: plant height jumps between frames {heights}")
    for problem in problems:
        print("FAIL:", problem)
    print("RESULT: " + ("OK" if not problems else f"FAIL ({len(problems)})"))
    return 0 if not problems else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if args.check:
        return check()
    if args.all:
        slugs = sorted(p.stem for p in SRC.glob("*.png") if not p.stem.startswith("_"))
    elif args.only:
        slugs = [args.only]
    else:
        ap.error("choose --only <herb>, --all or --check")
    dry = not args.build
    results = [build(slug, dry) for slug in slugs]
    print(f"\nRESULT: {'OK' if all(results) else 'FAIL'} ({sum(results)}/{len(results)})")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
