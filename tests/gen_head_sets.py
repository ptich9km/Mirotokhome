#!/usr/bin/env python3
"""Static 8-direction sprite sets for the city heads (quest givers).

Source: assets/units/_src/head_src/idle_dir{0..7}_*.png -- one saved pose per
world octant of the mage idle art (C:\\Work\\char_gen). The order of the files
IS the order the game indexes them by: 0 = down, 1 = down-left, 2 = left,
3 = up-left, 4 = up, 5 = up-right, 6 = right, 7 = down-right (see
Game.unit_octant). That is why the file names carry the direction.

The four races share ONE drawing. Three of them are palette swaps: the robe,
the skin and the hair/wood ramps are re-pointed at the race hues, and the
relative shading inside a ramp is preserved (t = position inside the source
ramp lightness range). No network, no paid generation.

Output geometry (measured on the existing sets, not guessed):
  * city citizens are 52x64 with a 58 px figure, feet on row 59-60;
  * the hero sets are 64x64 with a 54 px figure, feet on row 61.
The head is a citizen-class NPC and every city_* set is 52x64 (tests/city_npc_art_smoke.gd
enforces that contract), so the cell is 52x64 (cx 26, cy 62) with a 58 px figure and
the content bottom on row 61.

Usage:
  python tests/gen_head_sets.py --preview C:\\Temp\\head_sheet.png
  python tests/gen_head_sets.py --build
  python tests/gen_head_sets.py --check
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "assets" / "units" / "_src" / "head_src"
UNITS = REPO / "assets" / "units"

CELL_W = 52        # the city art contract: 52x64 (see tests/city_npc_art_smoke.gd)
CELL_H = 64
FIGURE_H = 58      # city citizens, measured on assets/units/city_* sets
FEET_ROW = 61      # content bottom row; the set pivot cy is 62
ALPHA_CUT = 128    # crisp edge: the source art is anti-aliased, the game uses NEAREST

# Source index == world octant == sprite file index (see Game.unit_octant).
FILES = [
    "idle_dir0_down.png",
    "idle_dir1_down-left.png",
    "idle_dir2_left.png",
    "idle_dir3_up-left.png",
    "idle_dir4_up.png",
    "idle_dir5_up-right.png",
    "idle_dir6_right.png",
    "idle_dir7_down-right.png",
]

## Race palette ramps: (dark, light) per material ramp. `None` = keep the drawing
## as it is. The values are RGB 0-255 at the ends of the ramp; every pixel keeps
## its own place between the ends, so the shading of the robe survives.
RACES = {
    "human": None,
    "ork": {
        "skin": ((64, 92, 52), (134, 176, 96)),    # olive-green orc skin
        "robe": ((36, 24, 22), (118, 70, 56)),     # worn mahogany leather cloak
        "hair": ((30, 24, 16), (104, 80, 48)),     # dark brown hair, staff, boots
        "trim": ((96, 74, 32), (186, 152, 78)),    # dull brass
    },
    "necro": {
        "skin": ((84, 94, 88), (168, 178, 166)),   # grey-green flesh
        "robe": ((22, 20, 32), (74, 68, 96)),      # dark violet shroud
        "hair": ((52, 52, 58), (148, 148, 156)),   # grey hair
        "trim": ((76, 76, 86), (166, 166, 178)),   # tarnished silver
    },
    "druid": {
        "skin": ((104, 76, 52), (198, 158, 116)),  # tanned skin
        "robe": ((40, 54, 32), (108, 132, 82)),    # moss green
        "hair": ((40, 32, 20), (116, 88, 54)),     # brown hair
        "trim": ((112, 94, 46), (204, 178, 96)),   # gold
    },
}

## Where a unit set lives and what the panels show in the tooltip.
LABELS = {
    "human": ("Глава города", "Горожанин-глава, человек"),
    "ork": ("Глава орков", "Горожанин-глава, орк"),
    "necro": ("Глава нежити", "Горожанин-глава, нежить"),
    "druid": ("Глава друидов", "Горожанин-глава, друид"),
}


def premul_resize(rgba: Image.Image, size: tuple[int, int]) -> np.ndarray:
    """Resize in premultiplied alpha.

    A plain RGBA resize mixes the RGB of fully transparent pixels (leftover
    background) into the figure; that is what makes cut frames look muddy
    (same lesson as the herb strips, 11.11).
    """
    a = np.asarray(rgba.convert("RGBA"), dtype=np.float32) / 255.0
    rgb_pre = a[..., :3] * a[..., 3:4]
    r = Image.fromarray(np.clip(rgb_pre * 255.0, 0, 255).astype(np.uint8), "RGB")
    al = Image.fromarray((a[..., 3] * 255.0).astype(np.uint8), "L")
    rn = np.asarray(r.resize(size, Image.LANCZOS), dtype=np.float32)
    an = np.asarray(al.resize(size, Image.LANCZOS), dtype=np.float32) / 255.0
    out = np.zeros((an.shape[0], an.shape[1], 4), dtype=np.float32)
    out[..., :3] = np.clip(rn / np.maximum(an, 1e-3)[..., None], 0, 255)
    out[..., 3] = an * 255.0
    return out


def hsv(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Vectorised HSV. rgb is 0..255 float. Returns H (0..360), S (0..1), V (0..1)."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    d = mx - mn
    v = mx / 255.0
    s = np.where(mx > 0.0, d / np.maximum(mx, 1e-6), 0.0)
    h = np.zeros_like(mx)
    active = d > 1e-6
    i_r = active & (mx == r)
    i_g = active & (mx == g) & ~i_r
    i_b = active & (mx == b) & ~i_r & ~i_g
    h[i_r] = (((g - b)[i_r] / d[i_r]) % 6.0)
    h[i_g] = ((b - r)[i_g] / d[i_g]) + 2.0
    h[i_b] = ((r - g)[i_b] / d[i_b]) + 4.0
    return h * 60.0, s, v


def classify(rgb: np.ndarray, opaque: np.ndarray, anchor_x: float) -> dict[str, np.ndarray]:
    """Split the drawing into material ramps by hue, saturation, lightness, position.

    The order matters: the gold piping of the robe is warmer than the skin and
    would otherwise be recoloured as skin.

    Skin vs hair: both are warm browns. Measured on the source face, shadowed skin
    sits at lightness 0.30-0.35 while the hair is 0.14-0.18, so 0.26 separates them.

    Skin is also limited in position -- the face band and the hand band -- because
    the staff wood is the same warm orange: measured staff rim = hue 27-33,
    sat 0.57-0.61, against a face of hue 24-34, sat 0.42-0.52 and hands of
    sat 0.46-0.54. Without the position limit an orc got a green staff crook.
    Saturation then keeps the lit staff rim out of the hand band as well.

    The face hue range is wide on purpose (24-34): a narrower window left the
    upper lip and the cheeks peach, and the orc read "half green faced" in game.
    """
    hue, sat, _val = hsv(rgb)
    light = (rgb.max(axis=-1) + rgb.min(axis=-1)) / 510.0
    h, w = rgb.shape[0], rgb.shape[1]
    rows = np.arange(h, dtype=np.float32)[:, None]
    cols = np.arange(w, dtype=np.float32)[None, :]
    face = np.broadcast_to(rows < h * 0.32, (h, w)) & \
        np.broadcast_to(np.abs(cols - anchor_x) < w * 0.24, (h, w))
    hands = np.broadcast_to((rows >= h * 0.38) & (rows <= h * 0.62), (h, w)) & \
        np.broadcast_to(np.abs(cols - anchor_x) < w * 0.45, (h, w))
    skin_area = face | hands
    warm = (hue >= 13.0) & (hue <= 34.0)
    masks: dict[str, np.ndarray] = {}
    taken = np.zeros_like(opaque)
    robe = opaque & ~taken & (hue >= 185.0) & (hue <= 325.0) & (sat > 0.10)
    masks["robe"] = robe
    taken |= robe
    trim = opaque & ~taken & (hue >= 35.0) & (hue <= 48.0) & (sat >= 0.40) & (light >= 0.36)
    masks["trim"] = trim
    taken |= trim
    skin_color = opaque & ~taken & skin_area & warm & (sat >= 0.24) & (sat <= 0.55) \
        & (light >= 0.26)
    # Gold piping of the robe has the same hue as the face (24-34), so the colour
    # and position rules alone left green speckles along the seams and the hem on
    # an orc. Skin comes in blobs (face, hands), the piping is a 1 px line: take the
    # blob cores (3 of 8 neighbours are skin too), then grow one pixel back inside
    # the same face/hand area. A strict cut alone left the lit forehead peach.
    core = skin_color & (neighbours8(skin_color) >= 3)
    skin = core | (skin_color & (neighbours8(core) >= 1))
    masks["skin"] = skin
    taken |= skin
    hair = opaque & ~taken & (hue >= 2.0) & (hue <= 48.0) & (light < 0.56)
    masks["hair"] = hair
    masks["rest"] = opaque & ~taken & ~hair
    return masks


def neighbours8(mask: np.ndarray) -> np.ndarray:
    """Count of the 8 neighbours that are set (arithmetic on the 3x3 window)."""
    k = np.zeros(mask.shape, dtype=np.int16)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            k += np.roll(np.roll(mask, dy, axis=0), dx, axis=1)
    return k


def normalize(index: int, race: str) -> tuple[np.ndarray, dict[str, tuple[float, float]]]:
    """One source frame -> one 52x64 cell of the requested race."""
    im = Image.open(SRC / FILES[index]).convert("RGBA")
    raw = np.asarray(im, dtype=np.int32)
    ys, xs = np.nonzero(raw[..., 3] > 40)
    if len(xs) == 0:
        raise SystemExit(f"empty frame: {FILES[index]}")
    im = im.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
    w = max(1, int(round(im.width * FIGURE_H / float(im.height))))
    arr = premul_resize(im, (w, FIGURE_H))
    arr[..., 3] = np.where(arr[..., 3] >= ALPHA_CUT, 255.0, 0.0)

    opaque = arr[..., 3] > 0.0
    rgb = np.clip(arr[..., :3], 0, 255)

    # Anchor on the head band, not on the bounding box: the staff sticks out to
    # the side and would drag the body off-centre between directions. It is also
    # what keeps the skin ramp off the staff (see classify()).
    band = arr[int(FIGURE_H * 0.08):int(FIGURE_H * 0.22), :, 3] > 0.0
    col_alpha = band.sum(axis=0).astype(np.float64)
    total = col_alpha.sum()
    cx = float((col_alpha * np.arange(col_alpha.size)).sum() / total) if total > 0 else w / 2.0

    ranges: dict[str, tuple[float, float]] = {}
    ramps = RACES[race]
    if ramps is not None:
        masks = classify(rgb, opaque, cx)
        light = (rgb.max(axis=-1) + rgb.min(axis=-1)) / 510.0
        for name, (dark, bright) in ramps.items():
            mask = masks.get(name)
            if mask is None or not mask.any():
                continue
            lo = float(np.percentile(light[mask], 5.0))
            hi = float(np.percentile(light[mask], 95.0))
            if hi - lo < 1e-3:
                hi = lo + 1e-3
            ranges[name] = (lo, hi)
            t = np.clip((light - lo) / (hi - lo), 0.0, 1.0)[..., None]
            target = np.array(dark, dtype=np.float32) + \
                (np.array(bright, dtype=np.float32) - np.array(dark, dtype=np.float32)) * t
            arr[..., :3] = np.where(mask[..., None], target, arr[..., :3])

    cell = np.zeros((CELL_H, CELL_W, 4), dtype=np.float32)
    x0 = int(round(CELL_W / 2.0 - cx))
    y0 = FEET_ROW - FIGURE_H + 1
    xs0, xs1 = max(0, x0), min(CELL_W, x0 + w)
    cell[y0:y0 + FIGURE_H, xs0:xs1] = arr[:, (xs0 - x0):(xs1 - x0)]
    return cell, ranges


def race_dir(race: str) -> Path:
    return UNITS / ("city_%s_head" % race) / "t0"


def build_race(race: str) -> list[tuple[Path, np.ndarray]]:
    out = []
    for i in range(len(FILES)):
        cell, _ = normalize(i, race)
        out.append((race_dir(race) / ("sprites-%03d.png" % (i + 1)), cell))
    return out


def save(cell: np.ndarray, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.clip(cell, 0, 255).astype(np.uint8), "RGBA").save(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", default="", help="path of the contact sheet to write")
    ap.add_argument("--build", action="store_true", help="write the four sprite sets")
    ap.add_argument("--check", action="store_true", help="compare the sets on disk with a rebuild")
    ap.add_argument("--races", default="", help="comma separated subset (default: all four)")
    ap.add_argument("--zoom", type=int, default=3, help="contact sheet zoom")
    args = ap.parse_args()

    races = [r.strip() for r in args.races.split(",") if r.strip()] or list(RACES)
    for r in races:
        if r not in RACES:
            print("unknown race: %s (known: %s)" % (r, ", ".join(RACES)))
            return 2

    if args.preview:
        zoom = max(1, args.zoom)
        sheet = Image.new("RGBA",
                          (CELL_W * 8 * zoom, CELL_H * len(races) * zoom), (28, 30, 40, 255))
        for row, race in enumerate(races):
            for i in range(len(FILES)):
                cell, _ = normalize(i, race)
                tile = Image.fromarray(np.clip(cell, 0, 255).astype(np.uint8), "RGBA")
                tile = tile.resize((CELL_W * zoom, CELL_H * zoom), Image.NEAREST)
                sheet.alpha_composite(tile, (i * CELL_W * zoom, row * CELL_H * zoom))
        path = Path(args.preview)
        path.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(path)
        print("preview: %s (%d x %d)" % (path, sheet.width, sheet.height))
        return 0

    if args.check:
        bad = 0
        for race in races:
            for path, cell in build_race(race):
                if not path.exists():
                    print("MISSING: %s" % path)
                    bad += 1
                    continue
                disk = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float32)
                want = np.clip(cell, 0, 255).astype(np.uint8)
                if disk.shape != want.shape or not np.array_equal(disk.astype(np.uint8), want):
                    print("STALE: %s" % path)
                    bad += 1
        print("RESULT: %s head sets (%d races x %d frames)"
              % ("OK" if bad == 0 else "FAIL", len(races), len(FILES)))
        return 0 if bad == 0 else 1

    if args.build:
        for race in races:
            for path, cell in build_race(race):
                save(cell, path)
            print("built %s (%d frames)" % (race_dir(race).parent.name, len(FILES)))
        return 0

    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
