#!/usr/bin/env python3
"""Stage 3: cut seedream nature sprites -> assets/map-objects/<name>/,
register in alm_objects.json (from 200)."""
import json
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "assets/map-objects/alm_objects.json"

# folder: (source, canvas_w, canvas_h) — trees tall, bushes/rocks smaller
SOURCES: dict[str, tuple[Path, int, int]] = {
    "tree_oak": (REPO / "import/_stage3_nature/tree_oak.png", 112, 128),
    "tree_oak2": (REPO / "import/_stage3_nature/tree_oak2.png", 112, 128),
    "tree_pine": (REPO / "import/_stage3_nature/tree_pine.png", 96, 128),
    "tree_birch": (REPO / "import/_stage3_nature/tree_birch.png", 96, 128),
    "tree_willow": (REPO / "import/_stage3_nature/tree_willow.png", 112, 112),
    "bush_berry": (REPO / "import/_stage3_nature/bush_berry.png", 64, 64),
    "palm": (REPO / "import/_stage3_nature/palm.png", 96, 128),
    "cactus": (REPO / "import/_stage3_nature/cactus.png", 64, 96),
    "tree_dead": (REPO / "import/_stage3_nature/tree_dead.png", 112, 128),
    "bush_thorn": (REPO / "import/_stage3_nature/bush_thorn.png", 64, 64),
    "rock": (REPO / "import/_stage3_nature/rock.png", 64, 56),
    "rock2": (REPO / "import/_stage3_nature/rock2.png", 64, 48),
    # Stage 4: small undergrowth. Canvas stays at the bush size (64) so the
    # clutter does not read as a tree; the mushroom is smaller on purpose.
    "mushroom_cluster": (REPO / "import/_stage4_props/mushroom_cluster.png", 48, 48),
    "fern": (REPO / "import/_stage4_props/fern.png", 64, 64),
    "dry_bush": (REPO / "import/_stage4_props/dry_bush.png", 64, 64),
    "aloe": (REPO / "import/_stage4_props/aloe.png", 64, 64),
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
    # объектом (просвет между ветвями, пятно в кроне), и та попадала в спрайт.
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
    db = json.loads(DB.read_text(encoding="utf-8"))
    existing_folders = {v.get("folder") for v in db.values() if isinstance(v, dict)}
    next_id = max(int(k) for k in db.keys()) + 1

    # 17.10: отсутствующий исходник больше НЕ роняет весь прогон. Исходники
    # `import/_stage3_nature` выборочно удалены (в репозитории их нет), и
    # `sys.exit(1)` делал невозможной перенарезку ОДНОГО объекта — а это ровно
    # то, что требовалось игроку. Пропуск тихим не сделан: в конце печатается
    # отчёт «нарезано/пропущено», и прогон без единой нарезки всё равно падает.
    cut, skipped = 0, []
    for folder, (src, cw, ch) in SOURCES.items():
        if not src.exists():
            print(f"SKIP нет исходника {src.name} (нарезка не выполнена)")
            skipped.append(folder)
            continue
        out_dir = REPO / "assets/map-objects" / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        content = cut_bg(src)
        sprite = fit_canvas(content, cw, ch)
        sprite.save(out_dir / "sprites-001.png")
        cut += 1
        print(f"cut {folder}: content={content.size} canvas={cw}x{ch}")

        if folder in existing_folders:
            for v in db.values():
                if isinstance(v, dict) and v.get("folder") == folder:
                    v["w"], v["h"] = cw, ch
                    v["cx"], v["cy"] = cw // 2, ch
                    break
            print("  exists, art+size refreshed")
            continue
        db[str(next_id)] = {
            "folder": folder, "index": 0, "w": cw, "h": ch,
            "cx": cw // 2, "cy": ch, "phases": 1, "frames": 1,
            "desc": f"Seedream {folder}",
        }
        print(f"  alm_objects +{next_id}")
        next_id += 1

    print(f"нарезано: {cut}, пропущено без исходника: {len(skipped)} {skipped}")
    if cut == 0:
        print("FAIL ничего не нарезано: переименуй исходник в import/_stage3_nature")
        sys.exit(1)

    DB.write_text(json.dumps(db, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print("done")


if __name__ == "__main__":
    main()
