#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Animated herb strips via KodikRouter (09.11).

Every herb on the map can sway. The pipeline is the same as for the heroes and
the Greys, only smaller:

  1. the model draws ONE strip: four poses of the same plant in a row on a flat
     magenta background;
  2. `gen_herb_strip.py` runs the shared preflight (four figures, gaps, nothing
     cut by the edge, one ground line);
  3. `extract_herb_strip.py` cuts it into `<slug>_frame00..03.png` at 32x32 with
     alpha and a common scale, so the plant does not pulse;
  4. `herbs_db.json` gets `frame_count: 4, fps: 6` and `HerbNode` animates it.

The game code is ready for this already: HerbNode reads the frame count from
HerbDB and looks for `<icon>_frameNN.png`, so the art is the only missing piece.

Cheap review order (the same rule as the hero strips): generate ONE herb, look
at the preview, run the preflight, and only then spend money on the rest.

Run:
    python tests/gen_herb_strip.py --list
    python tests/gen_herb_strip.py --only green_leaf --dry-run
    python tests/gen_herb_strip.py --only green_leaf
    python tests/gen_herb_strip.py --check import/herb_strips/green_leaf.png
    python tests/gen_herb_strip.py --all --skip-done
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_hero_strip import LAYOUT4, normalize_bg, preflight  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "import" / "herb_strips"
MANIFEST = OUT_DIR / "manifest.json"

## A real plant in the 1536x1024 sheet is ~350 px tall; specks of paint dust
## that the model leaves between the panels are 1-8 px. Below this height a
## run is not a figure (else "4 plants" reads as "6 figures").
MIN_FIGURE_H = 40

## Free model: the shape check costs nothing. A paid model is only worth it for
## the final sheets - pass --model to switch.
MODEL = "inclusionai/ming-image-0.1-design"
SIZE = "1536x1024"
SEED = 20261109

## What the herb has to look like. The icons are hand-painted in the same style,
## and the frames replace them on the map - a different style would clash.
STYLE = """ART STYLE: a hand-painted 2D RPG game asset, the same style as a small
32x32 inventory icon of a herb - soft painterly brushwork, warm saturated
colours, a dark thin outline, and simple readable shapes. NOT pixel art, NOT a
photo, NOT a 3D render, no gradient background."""

PLANT = """The plant is SMALL and SELF-CONTAINED: one whole plant with its root ball
of dark soil at the bottom, no pot, no patch of grass around it, no ground, no
shadow on the background. Every panel shows the SAME single plant - same species,
same amount of leaves, same colours, same size."""

## The four frames are a loop: frame 4 must flow back into frame 1.
SWAY = """AN ANIMATION OF A GENTLE WIND SWAY, 4 panels left to right in ONE row.
Panel 1: the plant stands upright and calm.
Panel 2: the stems and leaves bend slightly to the RIGHT, the whole plant leans
by a few degrees, the root ball stays exactly in place.
Panel 3: the plant is upright again, slightly stretched upwards, as if the gust
passed.
Panel 4: the stems bend slightly to the LEFT, a few degrees only.
The movement is SMALL - a few degrees of lean, like a light breeze. The plant never
bends over, never folds, never changes size and never loses or gains leaves. The
root ball and the ground line stay in exactly the same place in all four panels,
so the game can loop the frames without the plant jumping."""

HERBS = {
    "green_leaf": {
        "name": "a small herb of broad green leaves",
        "detail": ("five or six wide soft green leaves in a low rosette, a few "
                   "short pale stems, a small clump of dark brown soil with thin "
                   "roots at the bottom"),
    },
    "white_flower": {
        "name": "a small flowering herb",
        "detail": ("two or three small white five-petalled flowers with yellow "
                   "centres on thin green stems above a rosette of narrow leaves, "
                   "a small clump of dark soil at the bottom"),
    },
    "dandelion": {
        "name": "a small dandelion",
        "detail": ("a bright yellow dandelion flower head and one fluffy white seed "
                   "head on thin green hollow stems, a rosette of toothed leaves, a "
                   "small clump of dark soil at the bottom"),
    },
    "red_berry": {
        "name": "a small berry shrub",
        "detail": ("a low bush with oval green leaves and clusters of small glossy "
                   "red berries, a short woody stem, a small clump of dark soil at "
                   "the bottom"),
    },
    "tall_grass": {
        "name": "a tuft of tall grass",
        "detail": ("a tight tuft of long thin bright green blades with slightly "
                   "golden tips, a few thin seed stalks, a small clump of dark soil "
                   "at the bottom"),
    },
    "mint": {
        "name": "a small mint plant",
        "detail": ("square stems with paired serrated dark green mint leaves and a "
                   "few tiny pale lilac flowers, a small clump of dark soil at the "
                   "bottom"),
    },
    "lavender": {
        "name": "a small lavender bush",
        "detail": ("several tall thin stems with narrow grey-green leaves and long "
                   "violet flower spikes on top, a small clump of dark soil at the "
                   "bottom"),
    },
    "broad_leaf": {
        "name": "a small plant with very broad leaves",
        "detail": ("four or five large wide heart-shaped leaves with visible veins, "
                   "deep green with a blue tint, short thick stems, a small clump of "
                   "dark soil at the bottom"),
    },
    "glowmoss": {
        "name": "a small glowing moss",
        "detail": ("a low mound of fuzzy bright yellow-green moss with tiny luminous "
                   "spores glowing faintly, a couple of thin pale stalks, a small "
                   "clump of dark soil at the bottom"),
    },
    "shadow_fern": {
        "name": "a small dark fern",
        "detail": ("delicate deep violet-black fronds curled at the tips, a thin "
                   "dark stem, faint purple sheen on the edges, a small clump of "
                   "dark soil at the bottom"),
    },
    "astral_lotus": {
        "name": "a small astral lotus flower",
        "detail": ("one open pale lilac-and-teal lotus bloom with a glowing centre, "
                   "wide flat teal leaves around it, a small clump of dark soil at "
                   "the bottom"),
    },
    "ember_root": {
        "name": "a small plant with an ember root",
        "detail": ("dark olive scorched leaves and a short thick exposed root of "
                   "glowing orange-red ember colour, a few tiny sparks, a small "
                   "clump of dark soil at the bottom"),
    },
}


def build_prompt(slug: str) -> str:
    spec = HERBS[slug]
    character = (f"ONE single plant repeated in every panel: {spec['name']}, "
                 f"{spec['detail']}. The same individual plant in every panel.")
    return f"{character}\n\n{STYLE}\n\n{PLANT}\n\n{SWAY}\n\n{LAYOUT4}"


def _slug(value: str) -> str:
    return value.lower().replace(" ", "_").replace("herb_", "")


def _load_manifest() -> dict:
    if MANIFEST.exists():
        try:
            return json.loads(MANIFEST.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}
    return {}


def _save_manifest(data: dict) -> None:
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(data, indent=2, ensure_ascii=False),
                        encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="one herb, e.g. green_leaf")
    ap.add_argument("--all", action="store_true", help="every herb")
    ap.add_argument("--skip-done", action="store_true",
                    help="skip herbs whose strip is already on disk")
    ap.add_argument("--check", default="", help="preflight an existing sheet")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--seed", type=int, default=SEED)
    args = ap.parse_args()

    if args.list:
        for slug, spec in HERBS.items():
            print(f"{slug:14} {spec['name']}")
        print(f"\ntotal: {len(HERBS)}")
        return 0

    if args.check:
        ok, report = preflight(args.check, expect=4, min_gap=40, min_ratio=0.0,
                               min_figure_h=MIN_FIGURE_H)
        print(report)
        print("RESULT: " + ("OK" if ok else "FAIL"))
        return 0 if ok else 2

    if args.only:
        slugs = [_slug(args.only)]
        unknown = [s for s in slugs if s not in HERBS]
        if unknown:
            ap.error(f"unknown herb: {unknown[0]} (see --list)")
    elif args.all:
        slugs = list(HERBS)
    else:
        ap.error("choose --only <herb>, --all or --list")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest = _load_manifest()
    if args.dry_run:
        for slug in slugs:
            print("=" * 70)
            print(slug)
            print("=" * 70)
            print(build_prompt(slug))
        print(f"\nRESULT: OK (dry-run, {len(slugs)} prompt(s), nothing generated)")
        return 0

    from gen_image_kodik import gen_once, load_key

    key = load_key()
    total_cost = 0.0
    made: list[str] = []
    for slug in slugs:
        out = OUT_DIR / f"{slug}.png"
        if out.exists() and not args.force and (args.skip_done or not args.only):
            print(f"skip {slug}: {out.name} already exists (--force to redo)")
            continue
        print(f"--- {slug} ({args.model})")
        result = gen_once(key, args.model, build_prompt(slug), out, SIZE,
                          args.seed, 1, None)
        ## The model sometimes returns a muted magenta (188,37,132 instead of
        ## 255,0,255): preflight and the cutter both key on true magenta, so the
        ## background is snapped to it first (same step as the hero pipeline).
        replaced = normalize_bg(str(out))
        print(f"normalize_bg: {replaced} bg pixels -> pure magenta")
        ok, report = preflight(str(out), expect=4, min_gap=40, min_ratio=0.0,
                               min_figure_h=MIN_FIGURE_H)
        print(report)
        entry = manifest.setdefault(slug, {})
        entry.update({"model": args.model, "cost": result.get("cost"),
                      "prompt": build_prompt(slug), "preflight": "OK" if ok else "FAIL",
                      "file": str(out.relative_to(REPO)).replace("\\", "/")})
        try:
            total_cost += float(result.get("cost", 0) or 0)
        except (TypeError, ValueError):
            pass
        _save_manifest(manifest)
        if not ok:
            print(f"FAIL {slug}: preflight rejected the sheet, not adding it")
            continue
        made.append(slug)

    print(f"\ngenerated: {len(made)} {made}")
    print(f"cost: ${total_cost:.3f}")
    print("next: python tests/extract_herb_strip.py --only <herb> --build")
    return 0 if made or not slugs else 0


if __name__ == "__main__":
    sys.exit(main())
