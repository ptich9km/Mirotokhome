#!/usr/bin/env python3
"""Cut AI mission sheets into 64x64 animation frames.

Input: one sheet from `gen_mission_sheets.py` - four phases of one scene in a
row on flat magenta. Output: `assets/quests/missions/<slug>-000..003.png`
(RGBA, content bottom on y=62, content at most 54x54) - exactly what
`QuestIcons.mission_frames()` loads.

The alpha and the downscale are taken from the herb-strip pipeline on purpose:
both defects it fixes were measured there (11.11).
  * a colour-only background test deletes parts of the object - the mask is
    built from magenta pixels CONNECTED TO THE EDGE plus enclosed holes;
  * a straight RGBA resize mixes the magenta of fully transparent pixels into
    the object, so the frames come out with a green/pink fringe. Premultiplied
    resize makes transparent pixels contribute nothing.
One scale is used for all four frames: a per-frame fit makes the object breathe
in size between phases, which reads as a glitch, not as animation.

Run:
  python tests/extract_mission_sheets.py --sheet import/Missions/find_items_v1.png --slug find_items
  python tests/extract_mission_sheets.py --all
  python tests/extract_mission_sheets.py --check --slug find_items
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from extract_herb_strip import (  # noqa: E402
    _boxes,
    _fallback_columns,
    _figure_rgba,
    _resize_premultiplied,
)
from gen_mission_sheets import MISSIONS  # noqa: E402

## The uniform background every sheet is normalized to by the generator.
BG = np.array([255.0, 0.0, 255.0])

MISS_DIR = REPO / "import" / "Missions"
OUT_DIR = REPO / "assets" / "quests" / "missions"
CANVAS = 64
FOOT_Y = 62
MAX_H = 54
MAX_W = 54
FRAMES = 4


def _alpha_and_color(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Soft alpha plus the colour with the magenta background removed.

    A binary mask (inside / outside) is what left a violet halo on the metal
    bands: an anti-aliased edge pixel is half object and half magenta, and it
    keeps that mixed colour. Measured on the chest sheet (20.11): the bands read
    purple instead of steel.

    Magenta-ness is `min(R, B) - G` - 255 for the flat background, 0 or less for
    any real colour (wood, steel, gold, red, white, yellow, blue), so it gives the
    coverage directly. The colour is then un-mixed against the known background,
    which is the inverse of what the model actually drew.
    """
    r = rgb[..., 0].astype(np.float32)
    g = rgb[..., 1].astype(np.float32)
    b = rgb[..., 2].astype(np.float32)
    pink = np.minimum(r, b)
    alpha = np.clip(1.0 - (pink - g) / 220.0, 0.0, 1.0)
    ## Some sheets come back with a DARKER magenta PLATE behind the objects
    ## instead of the flat background (caravan, 20.11: a "studio" backdrop about
    ## 145 levels darker). Its magenta-ness is only ~80, so the soft value left a
    ## brown-grey rectangle around the wagon. Purple with both R and B above G is
    ## not a colour any real object in these sheets uses - wood, steel, gold,
    ## fire and cloth all keep at least one of R/B below G.
    plate = ((pink - g) > 55.0) & (b > g + 10.0) & (r > g + 10.0)
    alpha = np.where(plate, 0.0, alpha)
    ## Transition pixels right at the plate edge land near 0.3 and read as a
    ## dirty outline; anything that thin is background in a 64 px icon.
    alpha = np.where(alpha < 0.3, 0.0, alpha)
    a3 = alpha[..., None]
    color = (rgb.astype(np.float32) - (1.0 - a3) * BG) / np.maximum(a3, 1e-3)
    return alpha, np.clip(color, 0.0, 255.0)


def cut_frames(sheet_path: Path) -> list[Image.Image]:
    rgb = np.array(Image.open(sheet_path).convert("RGB")).astype(np.int32)
    alpha, color = _alpha_and_color(rgb)
    boxes = _boxes(alpha)
    if len(boxes) != FRAMES:
        print(f"note {sheet_path.name}: {len(boxes)} figure(s), splitting by columns")
        boxes = _fallback_columns(alpha)
    if len(boxes) != FRAMES:
        raise SystemExit(f"{sheet_path.name}: cannot find {FRAMES} panels - sheet rejected")
    figures = [_figure_rgba(color.astype(np.uint8), alpha, box) for box in boxes]
    max_w = max(f.width for f in figures)
    max_h = max(f.height for f in figures)
    scale = min(MAX_W / max_w, MAX_H / max_h, 1.0)
    frames: list[Image.Image] = []
    for fig in figures:
        new_w = max(1, int(round(fig.width * scale)))
        new_h = max(1, int(round(fig.height * scale)))
        small = _resize_premultiplied(fig, (new_w, new_h))
        canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        canvas.alpha_composite(small, ((CANVAS - new_w) // 2, FOOT_Y - new_h))
        frames.append(canvas)
    return frames


def contact_sheet(slug: str, frames: list[Image.Image]) -> Path:
    zoom = 4
    sheet = Image.new("RGBA", (CANVAS * zoom * len(frames), CANVAS * zoom),
                      (26, 20, 16, 255))
    for index, frame in enumerate(frames):
        big = frame.resize((CANVAS * zoom, CANVAS * zoom), Image.Resampling.NEAREST)
        sheet.alpha_composite(big, (index * CANVAS * zoom, 0))
    # Review art, not a game asset: it lives with the sources, where Godot
    # ignores it (.gdignore), instead of inside res:// assets.
    out = MISS_DIR / f"_{slug}_contact_sheet.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    return out


def process(sheet_path: Path, slug: str) -> int:
    frames = cut_frames(sheet_path)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for i, fr in enumerate(frames):
        fr.save(OUT_DIR / f"{slug}-{i:03d}.png")
    sheet = contact_sheet(slug, frames)
    print(f"{slug}: {len(frames)} frames from {sheet_path.name} -> "
          f"{OUT_DIR.name}/{slug}-000..{len(frames) - 1:03d}.png, "
          f"contact sheet {sheet.name}")
    return 0


def process_all() -> int:
    n = 0
    for slug in MISSIONS:
        sheets = [p for p in MISS_DIR.glob(f"{slug}_v*.png") if p.is_file()]
        if not sheets:
            print(f"(no sheet yet: {slug})")
            continue
        process(max(sheets, key=lambda p: int(p.stem.split("_v")[-1])), slug)
        n += 1
    print(f"extracted {n} sheets")
    return 0


def check(slug: str) -> int:
    ok = True
    for i in range(FRAMES):
        p = OUT_DIR / f"{slug}-{i:03d}.png"
        if not p.exists():
            print(f"CHECK {slug}[{i}]: MISSING {p}")
            ok = False
            continue
        im = Image.open(p)
        a = np.array(im)
        good = im.size == (CANVAS, CANVAS) and (a[..., 3] > 0).any()
        print(f"CHECK {slug}[{i}]: size={im.size} "
              f"alpha_max={a[..., 3].max() if im.size == (CANVAS, CANVAS) else '?'} "
              f"-> {'ok' if good else 'FAIL'}")
        ok = ok and good
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sheet", help="raw sheet to cut")
    ap.add_argument("--slug", help="slug for the frames")
    ap.add_argument("--all", action="store_true", help="extract every sheet in import/Missions/")
    ap.add_argument("--check", action="store_true", help="validate the frames of --slug")
    args = ap.parse_args()
    if args.check:
        if not args.slug:
            ap.error("--check needs --slug")
        return check(args.slug)
    if args.all:
        return process_all()
    if args.sheet and args.slug:
        return process(Path(args.sheet), args.slug)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
