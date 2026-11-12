"""Bake a static 3D prop (Quaternius nature kit and any other mesh) into a game
sprite of a fixed canvas and height.

Driver side: it runs Blender through `tests/render_3d_props_blender.py`, then
crops the render to its content, scales it to the requested height and anchors
the result to the bottom centre of the canvas - exactly how `object_db.json`
describes a prop (`w`, `h`, `cx = w/2`, `cy = h`).

    python tests/render_3d_props.py --spec props.json --out import/3d_src/_render

The spec is a JSON with `defaults` and a `models` list:

    {"defaults": {"azimuth": -35, "elevation": 20, "render_px": 512},
     "models": [{"mesh": "glTF/CommonTree_1.gltf", "name": "tree_q1",
                 "w": 112, "h": 128, "outline": true, "palette": 0}]}

`palette` > 0 quantizes the sprite to that many colours: the check for how a
painted 2D look survives the low-poly render.
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render_3d_frames import add_outline, content_bbox, find_blender  # noqa: E402

BLENDER_STAGE = Path(__file__).resolve().parent / "render_3d_props_blender.py"


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True, help="JSON with the models to bake")
    ap.add_argument("--base", default="", help="directory the spec's meshes are relative to")
    ap.add_argument("--out", required=True, help="output directory for the sprites")
    ap.add_argument("--blender", default="", help="path to the Blender executable")
    ap.add_argument("--keep-renders", action="store_true")
    ap.add_argument("--contact", default="", help="write a labelled contact sheet here")
    return ap.parse_args()


def render_raw(mesh: Path, job_out: Path, work: Path, cfg: dict,
               blender: Path) -> Path:
    manifest = work / (job_out.stem + ".json")
    job = {
        "mesh": str(mesh),
        "out": str(job_out),
        "manifest": str(manifest),
        "render_px": int(cfg["render_px"]),
        "azimuth": float(cfg["azimuth"]),
        "elevation": float(cfg["elevation"]),
        "margin": float(cfg.get("margin", 1.08)),
        "exposure": float(cfg.get("exposure", 0.0)),
        "key_energy": float(cfg.get("key_energy", 3.0)),
    }
    job_path = work / (job_out.stem + "_job.json")
    job_path.write_text(json.dumps(job, indent=1), encoding="utf-8")
    cmd = [str(blender), "--background", "--factory-startup",
           "--python", str(BLENDER_STAGE), "--", "--job", str(job_path)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not job_out.exists():
        tail = (result.stdout or "")[-4000:] + (result.stderr or "")[-4000:]
        raise SystemExit("Blender render failed for %s:\n%s" % (mesh.name, tail))
    return job_out


def bake(raw: Path, cfg: dict, out_path: Path) -> tuple:
    """Crop to content, scale to the canvas, anchor bottom centre."""
    img = Image.open(raw).convert("RGBA")
    box = content_bbox(img)
    if box is None:
        raise SystemExit("empty render: %s" % raw)
    fig = img.crop(box)
    w = int(cfg["w"])
    h = int(cfg["h"])
    pad = 1  # the outline grows the figure by 1px on each side
    scale = min((h - 2 * pad) / float(fig.height),
                (w - 2 * pad) / float(fig.width))
    tw = max(1, int(round(fig.width * scale)))
    th = max(1, int(round(fig.height * scale)))
    fig = fig.resize((tw, th), Image.LANCZOS)
    # Clean-up pass: a LANCZOS downscale of a 1024px render is soft, and a soft
    # sprite next to the painted ones reads as "out of focus". Unsharp brings
    # the silhouette and the facet edges back without adding detail.
    if bool(cfg.get("sharpen", True)):
        fig = fig.filter(ImageFilter.UnsharpMask(radius=1.0, percent=90,
                                                 threshold=2))
    # Colour grade: the painted props carry far more internal contrast (deep
    # shadows between leaf clusters) than a uniform 3D render. Measured on the
    # 1x sheet, the bake reads "washed out" next to them.
    contrast = float(cfg.get("contrast", 1.0))
    if contrast != 1.0:
        fig = ImageEnhance.Contrast(fig).enhance(contrast)
    saturation = float(cfg.get("saturation", 1.0))
    if saturation != 1.0:
        fig = ImageEnhance.Color(fig).enhance(saturation)
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    canvas.alpha_composite(fig, ((w - tw) // 2, h - pad - th))
    if bool(cfg.get("outline", False)):
        canvas = add_outline(canvas)
    palette = int(cfg.get("palette", 0))
    if palette > 0:
        canvas = quantize(canvas, palette)
    canvas.save(out_path)
    return canvas, tw, th


def quantize(img: Image.Image, colors: int) -> Image.Image:
    """Palette-reduce the visible pixels only: the alpha channel stays as is."""
    rgba = img.convert("RGBA")
    alpha = rgba.getchannel("A")
    rgb = rgba.convert("RGB")
    quant = rgb.quantize(colors=colors, method=Image.MEDIANCUT,
                         dither=Image.NONE).convert("RGB")
    out = quant.convert("RGBA")
    out.putalpha(alpha)
    return out


def contact_sheet(items: list, path: Path, scale: int = 3) -> None:
    """Labelled sheet at a zoom: a sprite judged at 1x hides its own artefacts."""
    if not items:
        return
    cells = [(name, Image.open(src).convert("RGBA")) for name, src in items]
    gap = 8
    label_h = 14
    cell_w = max(im.width for _, im in cells) * scale
    cell_h = max(im.height for _, im in cells) * scale
    cols = min(4, len(cells))
    rows = (len(cells) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * (cell_w + gap) + gap,
                               rows * (cell_h + label_h + gap) + gap),
                      (34, 34, 38, 255))
    draw = ImageDraw.Draw(sheet)
    for n, (name, im) in enumerate(cells):
        col = n % cols
        row = n // cols
        x = gap + col * (cell_w + gap)
        y = gap + row * (cell_h + label_h + gap)
        big = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
        sheet.alpha_composite(big, (x + (cell_w - big.width) // 2,
                                    y + label_h + (cell_h - big.height) // 2))
        draw.text((x + 2, y + 1), name, fill=(220, 220, 220, 255))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)


def main() -> None:
    args = parse_args()
    spec = json.loads(Path(args.spec).read_text(encoding="utf-8"))
    base = Path(args.base) if args.base else Path(args.spec).resolve().parent
    common = dict(spec.get("defaults", {}))
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    blender = find_blender(args.blender)
    print("blender:", blender)

    work = Path(tempfile.mkdtemp(prefix="props_"))
    made = []
    for model in spec["models"]:
        cfg = dict(common)
        cfg.update(model)
        mesh = Path(cfg["mesh"])
        if not mesh.is_absolute():
            mesh = base / mesh
        if not mesh.exists():
            raise SystemExit("mesh not found: %s" % mesh)
        name = str(cfg.get("name") or mesh.stem)
        raw = render_raw(mesh, work / (name + "_raw.png"), work, cfg, blender)
        target = out_dir / (name + ".png")
        canvas, tw, th = bake(raw, cfg, target)
        print("%-22s %dx%d content %dx%d" % (name, canvas.width, canvas.height, tw, th))
        made.append((name, target))
    if args.contact:
        contact_sheet(made, Path(args.contact))
        print("contact sheet:", args.contact)
    if not args.keep_renders:
        for f in work.glob("*"):
            f.unlink(missing_ok=True)
        work.rmdir()


main()
