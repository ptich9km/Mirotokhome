#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cut the Kimi townsman sheet (4x4, RGBA, transparent bg) into game frames.

Input: import/kimi_human_townsman_spritesheet.png - 16 panels in a strict
4x4 grid, one figure per panel, warm spotlight glow around each figure on a
fully transparent background.

Output: import/townsman_out/frame01..16.png on the shared 64x64 unit canvas
(content height 54 px, feet on row 62, horizontal centre x=32) plus
_contact_sheet.png for the visual check.

The glow is the sheet-specific problem: it is warm and mostly opaque, so a
plain alpha bbox would measure the halo, not the man. Two steps kill it:

  * soft alpha threshold - the halo is dimmer at its rim, so
    a2 = clip((a - GLOW_T) * 255 / (255 - GLOW_T)) erases the fringe
    before the bbox is measured;
  * ONE scale for all 16 frames (max figure height across the sheet),
    otherwise the walk cycle "breathes" in size.

Frames are numbered row-major: 01-04 idle, 05-08 walk, 09-12 attack,
13-16 die. Nothing is written into assets/ - the units_db entry is a
separate, player-approved step.

Run:
    py tests/extract_kimi_townsman.py --preview
    py tests/extract_kimi_townsman.py --build
    py tests/extract_kimi_townsman.py --check
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
DST = REPO / "import" / "townsman_out"
SHEET = DST / "_contact_sheet.png"
REPORT = DST / "_report.json"

DEFAULT_SRC = REPO / "import" / "kimi_human_townsman_spritesheet.png"

GRID = 4                     # 4 rows x 4 cols
## 16 sheet panels -> the 12-frame unit contract (idle1+move4+attack3+dying4):
## idle = panel 1, move = panels 5-8, attack = panels 10-12 (the wind-up panel
## 9 is dropped: drive -> fully extended -> recoil reads better as 3 phases),
## die = panels 13-16.
CONTRACT_MAP = [1, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16]
GLOW_T = 48                  # soft alpha threshold that erases the halo rim
CANVAS = 64                  # shared unit canvas (hero contract)
CONTENT_H = 54               # max figure height inside the canvas
FEET_Y = 62                  # bottom row of the figure (FEETS_PAD = 2)


def _glow_free_alpha(a: np.ndarray) -> np.ndarray:
    """Alpha with the warm spotlight halo pressed down."""
    return np.clip((a.astype(np.int32) - GLOW_T) * 255 // (255 - GLOW_T), 0, 255).astype(np.uint8)


def _largest_component(mask: np.ndarray) -> np.ndarray:
    """Keep only the largest 4-connected component of a boolean mask.

    The sheet bleeds across panel borders: a piece of the panel below
    (frame 09) and a piece of the right neighbour (frame 15) land inside
    the cell as OPAQUE pixels the glow threshold cannot kill. The figure
    is the largest blob, the bleed is not connected to it, so
    keep-largest removes the debris without touching the silhouette.
    Runs on a 4x downsampled mask (block-max) - 16k cells instead of
    262k, pure Python is fast enough, and a block survives only if its
    whole 4x4 neighbourhood belongs to the main body.
    """
    h, w = mask.shape
    sh, sw = h // 4, w // 4
    small = mask[: sh * 4, : sw * 4].reshape(sh, 4, sw, 4).max(axis=(1, 3))
    # two-pass CCL with union-find over the downsampled grid
    parent = list(range(sh * sw))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    labels = np.full((sh, sw), -1, dtype=np.int32)
    nxt = 0
    for y in range(sh):
        for x in range(sw):
            if not small[y, x]:
                continue
            up = labels[y - 1, x] if y > 0 else -1
            lf = labels[y, x - 1] if x > 0 else -1
            if up < 0 and lf < 0:
                labels[y, x] = nxt
                nxt += 1
            elif up >= 0 and lf < 0:
                labels[y, x] = up
            elif lf >= 0 and up < 0:
                labels[y, x] = lf
            else:
                labels[y, x] = up
                union(up, lf)
    if nxt == 0:
        return mask
    sizes: dict[int, int] = {}
    best, best_sz = -1, -1
    for i in range(nxt):
        sizes[i] = 0
    for y in range(sh):
        for x in range(sw):
            if labels[y, x] >= 0:
                labels[y, x] = find(labels[y, x])
    for i in range(nxt):
        sz = int((labels == i).sum())
        if sz > best_sz:
            best, best_sz = i, sz
    keep = labels == best
    # dilate the surviving blocks by 1 so antialiased edge blocks survive
    keep_d = keep.copy()
    keep_d[1:, :] |= keep[:-1, :]
    keep_d[:-1, :] |= keep[1:, :]
    keep_d[:, 1:] |= keep[:, :-1]
    keep_d[:, :-1] |= keep[:, 1:]
    big = np.repeat(np.repeat(keep_d, 4, axis=0), 4, axis=1)
    out = mask & big
    if h % 4 or w % 4:  # leftover border rows/cols belong to no block
        out[sh * 4 :, :] = False
        out[:, sw * 4 :] = False
    return out


def _bbox(a: np.ndarray) -> tuple[int, int, int, int] | None:
    solid = a if a.dtype == bool else a > 16
    ys, xs = np.nonzero(solid)
    if ys.size == 0:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def cut_cells(im: Image.Image) -> list[Image.Image]:
    """Split the sheet into 16 cells on the strict 4x4 grid."""
    w, h = im.size
    cw, ch = w // GRID, h // GRID
    cells = []
    for row in range(GRID):
        for col in range(GRID):
            cells.append(im.crop((col * cw, row * ch, (col + 1) * cw, (row + 1) * ch)))
    return cells


def measure(cells: list[Image.Image]) -> list[tuple[int, int, int, int]]:
    """Glow-free bbox of every figure; aborts if a panel is empty."""
    boxes = []
    for i, cell in enumerate(cells):
        a = _glow_free_alpha(np.asarray(cell.getchannel("A")))
        box = _bbox(_largest_component(a > 16))
        if box is None:
            raise SystemExit(f"frame {i + 1}: empty panel, sheet layout is not 4x4")
        boxes.append(box)
    return boxes


def place(cell: Image.Image, box: tuple[int, int, int, int], scale: float) -> Image.Image:
    """Crop one figure and drop it on the shared 64x64 canvas.

    Downscale runs in premultiplied alpha: raw RGBA resize blends the RGB of
    near-transparent pixels (glow leftovers) into the silhouette and the
    frame comes out muddy.
    """
    x0, y0, x1, y1 = box
    fig = cell.crop((x0, y0, x1, y1))
    arr = np.dstack([np.asarray(fig.getchannel(c), dtype=np.float32) / 255.0 for c in "RGB"])
    a = np.asarray(fig.getchannel("A"), dtype=np.float32) / 255.0
    prem = np.dstack([arr[..., c] * a for c in range(3)] + [a])
    img = Image.fromarray((prem * 255).astype(np.uint8), "RGBA")
    nw = max(1, round(img.width * scale))
    nh = max(1, round(img.height * scale))
    img = img.resize((nw, nh), Image.LANCZOS)
    # back to straight alpha
    p = np.asarray(img, dtype=np.float32) / 255.0
    al = p[..., 3:4]
    al = np.where(al < 1e-3, 1.0, al)
    rgb = np.clip(p[..., :3] / al, 0, 1)
    img = Image.fromarray((np.dstack([rgb, p[..., 3]]) * 255).astype(np.uint8), "RGBA")

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    cx = (CANVAS - img.width) // 2
    canvas.paste(img, (cx, FEET_Y - img.height), img)
    return canvas


def run(src: Path, out: Path) -> dict:
    src = src.resolve()
    out = out.resolve()
    im = Image.open(src).convert("RGBA")
    cells = cut_cells(im)
    boxes = measure(cells)
    heights = [b[3] - b[1] for b in boxes]
    scale = CONTENT_H / max(heights)
    frames = [place(c, b, scale) for c, b in zip(cells, boxes)]
    out.mkdir(parents=True, exist_ok=True)
    for i, f in enumerate(frames):
        f.save(out / f"frame{i + 1:02d}.png")
    cols = 8
    rows = (len(frames) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * CANVAS * 2, rows * CANVAS * 2), (40, 40, 48, 255))
    for i, f in enumerate(frames):
        big = f.resize((CANVAS * 2, CANVAS * 2), Image.NEAREST)
        sheet.paste(big, ((i % cols) * CANVAS * 2, (i // cols) * CANVAS * 2), big)
    sheet.convert("RGB").save(out / "_contact_sheet.png")
    report = {
        "src": str(src.relative_to(REPO)),
        "grid": f"{GRID}x{GRID}",
        "scale": round(scale, 4),
        "figure_h_px": [round(h * scale, 1) for h in heights],
        "out": str(out.relative_to(REPO)),
    }
    (out / "_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def emit_game(src: Path, game_dir: Path) -> None:
    """Write the 12 game frames sprites-001..012 into assets/units/<game_dir>."""
    im = Image.open(src.resolve()).convert("RGBA")
    cells = cut_cells(im)
    boxes = measure(cells)
    heights = [b[3] - b[1] for b in boxes]
    scale = CONTENT_H / max(heights)
    out = REPO / "assets" / "units" / game_dir
    out.mkdir(parents=True, exist_ok=True)
    for i, panel in enumerate(CONTRACT_MAP):
        frame = place(cells[panel - 1], boxes[panel - 1], scale)
        frame.save(out / f"sprites-{i + 1:03d}.png")
    print(f"game frames -> {out.relative_to(REPO)} ({len(CONTRACT_MAP)} frames)")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(DEFAULT_SRC), help="input sheet PNG")
    ap.add_argument("--out", default=str(DST), help="output folder")
    ap.add_argument("--preview", action="store_true", help="print the plan, write nothing")
    ap.add_argument("--build", action="store_true", help="cut and write frames")
    ap.add_argument("--check", action="store_true", help="verify the written frames")
    ap.add_argument("--game", metavar="DIR", help="write the 12 contract frames into assets/units/DIR")
    args = ap.parse_args()
    out = Path(args.out)
    src = Path(args.src)
    if args.game:
        emit_game(src, args.game)
        return
    if args.preview:
        im = Image.open(src).convert("RGBA")
        cells = cut_cells(im)
        boxes = measure(cells)
        hs = [b[3] - b[1] for b in boxes]
        print(f"sheet {im.size}, 16 panels, figure heights {min(hs)}..{max(hs)} px")
        print(f"scale -> {CONTENT_H / max(hs):.4f}, canvas {CANVAS}x{CANVAS}, feet y={FEET_Y}")
        return
    if args.build:
        print(json.dumps(run(src, out), indent=2))
        return
    if args.check:
        ok = True
        for i in range(1, GRID * GRID + 1):
            p = out / f"frame{i:02d}.png"
            if not p.exists():
                print(f"MISSING {p.name}")
                ok = False
                continue
            f = Image.open(p)
            a = np.asarray(f.getchannel("A"))
            ys, _ = np.nonzero(a > 16)
            feet = int(ys.max()) if ys.size else -1
            status = "OK" if f.size == (CANVAS, CANVAS) and ys.size and feet <= FEET_Y else "BAD"
            if status == "BAD":
                ok = False
            print(f"{p.name} {f.size} figure_feet={feet} {status}")
        raise SystemExit(0 if ok else 1)
    ap.print_help()


if __name__ == "__main__":
    main()
