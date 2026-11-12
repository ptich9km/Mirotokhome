#!/usr/bin/env python3
"""Stage 4: fill the poor biomes (sand had 3 objects, mud 4) with our own props.

Same style block as stage 3, so mushrooms do not look like they were painted by
a different artist: the words that force chunky readable shapes are imported
from `_gen_stage3_nature` instead of being copied.

    python tests/_gen_stage4_props.py                 # everything missing
    python tests/_gen_stage4_props.py --only fern     # one prop
    python tests/_gen_stage4_props.py --force         # redraw existing
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_image_kodik import contact_sheet, gen_once, load_key  # noqa: E402
from _gen_stage3_nature import BG, STYLE  # noqa: E402

# What the map is actually short of. Prompt notes are the ones that cost a
# re-generation each time they are forgotten: mushrooms lose their stems to
# thin filaments, a fern turns into a lace doily, dried scrub into wires.
PROMPTS = {
    "mushroom_cluster": (
        "Cluster of three chunky mushrooms with thick rounded brown caps and "
        "short thick pale stems, growing on a small patch of dark moss, "
        "forest floor decoration, thick short stems, no thin gills, "
        f"{STYLE}, {BG}"),
    "fern": (
        "Bushy green fern with a few thick curved fronds spread in a rosette, "
        "forest undergrowth plant, thick leaf blades, no thin lace fronds, "
        "no delicate filigree leaves, "
        f"{STYLE}, {BG}"),
    "dry_bush": (
        "Withered dry shrub with thick tangled pale straw-yellow twigs and a few "
        "dead curled leaves, low desert scrub, thick woody stems, no thin wires, "
        "pale straw and warm grey only, no purple, no green leaves, "
        f"{STYLE}, {BG}"),
    "aloe": (
        "Desert aloe plant with a rosette of thick spiky grey-green leaves and "
        "a few red-tipped thorns, succulent desert plant, thick fleshy leaves, "
        f"{STYLE}, {BG}"),
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma separated prop names")
    ap.add_argument("--model", default="bytedance-seed/seedream-5-0-flash")
    ap.add_argument("--n", type=int, default=1, help="variants per prompt")
    ap.add_argument("--force", action="store_true", help="redraw existing")
    args = ap.parse_args()

    key = load_key()
    out_dir = Path(__file__).parent.parent / "import" / "_stage4_props"
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.only:
        wanted = [s.strip() for s in args.only.split(",") if s.strip()]
        unknown = [w for w in wanted if w not in PROMPTS]
        if unknown:
            raise SystemExit(f"unknown prop(s): {unknown}")
        prompts = {k: PROMPTS[k] for k in wanted}
    else:
        prompts = PROMPTS

    results = []
    for name, prompt in prompts.items():
        for i in range(args.n):
            suffix = "" if args.n == 1 else f"_c{i}"
            out = out_dir / f"{name}{suffix}.png"
            if out.exists() and not args.force:
                print(f"skip {out}")
                results.append({"model": args.model, "out": str(out),
                                "cost": 0, "sec": 0})
                continue
            try:
                results.append(gen_once(key, args.model, prompt, out,
                                        "1024x1024",
                                        seed=5000 + (hash(name) % 100) + i * 7,
                                        n=1, extra=None))
            except SystemExit as e:
                print(f"FAIL {name}{suffix}: {e}")

    ok = [r for r in results if Path(r["out"]).exists()]
    contact_sheet([Path(r["out"]) for r in ok],
                  out_dir / "_sheet.png",
                  labels=[Path(r["out"]).stem for r in ok], cell=384)
    total = sum(float(r["cost"] or 0) for r in results)
    print(f"\ntotal cost: ${total:.3f}")
    print(f"sheet: {out_dir / '_sheet.png'}")


if __name__ == "__main__":
    main()
