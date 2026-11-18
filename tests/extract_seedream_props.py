#!/usr/bin/env python3
"""Stage 2: cut seedream props -> assets/map-objects/<name>/sprites-001.png,
register free uint8 IDs in alm_objects.json (from 193)."""
import json
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "assets/map-objects/alm_objects.json"

# approved props (lantern_b rejected by player)
# canvas smaller than buildings: prop should read as clutter, not a building
SOURCES: dict[str, tuple[Path, int, int]] = {
    # folder: (source, canvas_w, canvas_h)
    "prop_barrel": (REPO / "import/_stage2_props/barrel.png", 40, 40),
    "prop_barrel2": (REPO / "import/_stage2_props/barrel_b.png", 40, 48),
    "prop_crate": (REPO / "import/_stage2_props/crate.png", 40, 40),
    "prop_crate2": (REPO / "import/_stage2_props/crate_b.png", 44, 48),
    "prop_lantern": (REPO / "import/_stage2_props/lantern.png", 32, 56),
    "prop_sack": (REPO / "import/_stage2_props/sack.png", 40, 40),
    "prop_pot": (REPO / "import/_stage2_props/pot.png", 32, 32),
    # Caravan cart (19.11): ingots + sack, pulled by a shaft. Slightly wider than
    # a crate because it is a centrepiece of the caravan event, not clutter.
    "prop_cart": (REPO / "import/_stage2_props/cart.png", 64, 56),
}

BG_TOL = 110


def cut_bg(path: Path) -> Image.Image:
    im = Image.open(path).convert("RGB")
    a = np.asarray(im, dtype=np.int16)
    border = np.concatenate([
        a[0, :].reshape(-1, 3), a[-1, :].reshape(-1, 3),
        a[:, 0].reshape(-1, 3), a[:, -1].reshape(-1, 3),
    ])
    bg_color = np.median(border, axis=0)
    dist = np.abs(a - bg_color).sum(axis=2)
    bg = dist <= BG_TOL
    # Фон определяется ЦВЕТОМ, без заливки от краёв: мадженты в арте нет, её
    # и выбрали фоном именно поэтому. Заливка оставляла магенту, окружённую
    # объектом, и та попадала в спрайт (игрок видел её на фонаре).
    alpha = np.where(bg, 0, 255).astype(np.uint8)
    rgba = np.dstack([np.asarray(im), alpha])
    ys, xs = np.where(alpha > 0)
    if len(ys) == 0:
        raise RuntimeError(f"empty cutout: {path}")
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    return Image.fromarray(rgba[y0:y1, x0:x1], "RGBA")


def kill_halo(rgba: np.ndarray) -> np.ndarray:
    r = rgba[:, :, 0].astype(np.int16)
    g = rgba[:, :, 1].astype(np.int16)
    b = rgba[:, :, 2].astype(np.int16)
    a = rgba[:, :, 3]
    magenta = (g < 90) & ((r - g) > 90) & ((b - g) > 70)
    transparent = a <= 8
    has_trans = np.zeros_like(transparent)
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            has_trans |= np.roll(np.roll(transparent, dy, 0), dx, 1)
    out = rgba.copy()
    out[magenta & has_trans & (a > 0), 3] = 0
    return out


def fit_canvas(content: Image.Image, cw: int, ch: int) -> Image.Image:
    scale = min(cw / content.size[0], ch / content.size[1])
    nw, nh = max(1, int(round(content.size[0] * scale))), max(1, int(round(content.size[1] * scale)))
    resized = content.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    canvas.paste(resized, ((cw - nw) // 2, ch - nh), resized)
    arr = np.asarray(canvas).copy()
    return Image.fromarray(kill_halo(arr), "RGBA")


def main() -> None:
    # Optional filter: `python extract_seedream_props.py --only prop_cart`.
    # The rest of the sources lived in `import/_stage2_props/`, which is scratch
    # space and gets cleaned; without the filter the run dies on a missing file.
    want = set(a for a in sys.argv[1:] if not a.startswith("--"))
    db = json.loads(DB.read_text(encoding="utf-8"))
    existing_folders = {v.get("folder") for v in db.values() if isinstance(v, dict)}
    next_id = max(int(k) for k in db.keys()) + 1

    for folder, (src, cw, ch) in SOURCES.items():
        if want and folder not in want:
            continue
        if not src.exists():
            print(f"FAIL missing {src}")
            sys.exit(1)
        out_dir = REPO / "assets/map-objects" / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        content = cut_bg(src)
        sprite = fit_canvas(content, cw, ch)
        out_png = out_dir / "sprites-001.png"
        sprite.save(out_png)
        print(f"cut {folder}: content={content.size} canvas={cw}x{ch}")

        if folder in existing_folders:
            for v in db.values():
                if isinstance(v, dict) and v.get("folder") == folder:
                    v["w"], v["h"] = cw, ch
                    v["cx"], v["cy"] = cw // 2, ch
                    break
            print(f"  exists, art+size refreshed")
            continue
        db[str(next_id)] = {
            "folder": folder, "index": 0, "w": cw, "h": ch,
            "cx": cw // 2, "cy": ch, "phases": 1, "frames": 1,
            "desc": f"Seedream prop {folder}",
        }
        print(f"  alm_objects +{next_id}")
        next_id += 1

    DB.write_text(json.dumps(db, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print("done")


if __name__ == "__main__":
    main()
