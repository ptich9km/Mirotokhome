#!/usr/bin/env python3
"""Generate mission sheets for the town heads - raw sheets go to import/Missions/.

A sheet is 4 panels in ONE row, one scene per panel: the animation of a mission
type in 4 phases (rest -> action -> action -> back to rest). The game cuts the
panels apart (tests/extract_mission_sheets.py) into 64x64 frames.

Model: bytedance-seed/seedream-5-0-flash ($0.018 per sheet, the same pipeline
that drew the herb strips). microsoft/mai-image-2.6-flash used by the first
draft of this script no longer exists in the router catalog (checked 20.11).

Run:
  python tests/gen_mission_sheets.py --list                 # mission catalog
  python tests/gen_mission_sheets.py --dry-run              # prompts, no cost
  python tests/gen_mission_sheets.py --slug find_items      # sheet find_items_v<n+1>
  python tests/gen_mission_sheets.py --slug find_items --v 1
  python tests/gen_mission_sheets.py --all
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_hero_strip import normalize_bg  # noqa: E402

MISS_DIR = REPO / "import" / "Missions"
MODEL = "bytedance-seed/seedream-5-0-flash"
SIZE = "1536x1024"
COST_PER_SHEET = 0.018

# The layout block is tuned by the herb strips (12 sheets, 11.11) and the hero
# strips: the model repeats a sequence twice or spills it into a second row when
# the panel rules are not stated. It stays separate from the scene text so every
# mission reuses the same hard rules.
LAYOUT_TAIL = """PURPOSE, read this first: you are drawing ONE SHEET WITH 4 PANELS IN ONE ROW
for a 2D fantasy tactical RPG. Every panel is a SEPARATE ANIMATION FRAME of one
scene - the game cuts the panels apart and plays them one after another.

COUNT IS LAW: draw EXACTLY 4 separate pictures in the whole image, never 5,
never 7. Do not repeat a panel and do not add an extra panel to finish the
motion. When the fourth picture is drawn, STOP. There is NO second row: the
whole area below the panels stays empty background.

LAYOUT RULES:
- exactly 4 separate pictures in a single horizontal row, evenly spaced
- every panel shows the same subject at the same size, nothing cropped
- empty gaps of pure background between neighbouring panels, at least 120
  pixels from the right edge of one panel to the left edge of the next one
- every panel keeps a strip of clear empty background on all four sides; nothing
  may touch or cross the border of the image
- keep each panel small: at most 18 percent of the image width and at most 45
  percent of the image height

ABSOLUTELY NO GROUND SHADOW, no cast shadow, no dark blur underneath, no floor,
no ground plane, no horizontal line, no surface, no reflection. The area around
every panel is the same flat background as the rest of the image.

Background: one single flat vivid magenta (255, 0, 255), perfectly uniform.
EXCLUDE: text, letters, numbers, captions, grid lines, borders, frames, signature,
watermark, duplicate panels, smoke, dust clouds, coloured haze."""

MISSIONS = {
    "find_items": {
        "note": "an opening chest - find-the-item missions",
        "prompt": """ONE old wooden CHEST (trunk), seen from the front, the same chest in
every panel:
Panel 1: lid fully closed.
Panel 2: lid half open by about a third, the hinge edge visible, the interior dark.
Panel 3: lid open, a faint golden glow inside the open box.
Panel 4: lid fully open, the glow clearly visible inside, a few herb sprigs and
a small coin at the bottom of the open box.""",
    },
    "destroy": {
        "note": "two swords clashing - destroy missions",
        "prompt": """TWO broad-bladed SWORDS clashing, the same pair in every panel:
Panel 1: both blades raised, wide apart, about to strike.
Panel 2: one blade swings down toward the other.
Panel 3: the blades strike together and cross, a burst of white-yellow sparks at
the crossing point.
Panel 4: the blades spring apart again, sparks fading.""",
    },
    "alchemy_gather": {
        "note": "a daisy swaying - alchemy gathering missions",
        "prompt": """ONE white DAISY with a green stem and two leaves, the same flower in every
panel, swaying slowly in the wind:
Panel 1: flower upright, facing the camera.
Panel 2: flower tilted right by about 20 degrees, leaves bent with it.
Panel 3: flower tilted left by about 20 degrees, a mirror pose.
Panel 4: flower upright again.""",
    },
    "escort": {
        "note": "two people walking hand in hand - escort missions",
        "prompt": """TWO small humanoid FIGURES walking side by side, holding hands, the same pair
in every panel: one in a simple travelling cloak with a bundle on the back, the
other in a plain tunic, seen from the side, moving to the right.
Panel 1: the pair walking, arms linked, one leg forward.
Panel 2: the next step, the linked hands stay together.
Panel 3: the next step again, the cloak figure slightly ahead.
Panel 4: the next step, the same walking pose as panel 2.""",
    },
    "build_repair": {
        "note": "bricks and a trowel at work - build / repair missions",
        "prompt": """A small stack of RED BRICKS and a mason's TROWEL with a dab of grey mortar,
the same objects in every panel:
Panel 1: three bricks stacked in a row, the trowel resting on top, no motion.
Panel 2: the trowel lifted with a brick on its flat part, moving to the right.
Panel 3: the brick being set down against the stack, mortar squeezed out.
Panel 4: four bricks now in the stack, the trowel resting again.""",
    },
    "caravan": {
        "note": "a wagon with glowing ingots - caravan missions",
        "prompt": """An old open two-wheel WAGON shown from the side with three GOLD INGOTS
piled inside, the same wagon in every panel, the ingots shining with a warm
golden light:
Panel 1: the ingots glowing dimly.
Panel 2: the glow brightens on the top ingot.
Panel 3: the brightest phase, light rays from all three ingots.
Panel 4: the glow dims again, the same pose as panel 1.""",
    },
    "boss_kill": {
        "note": "a dragon eye and a sword pacing - boss-kill missions",
        "prompt": """A big glowing RED DRAGON'S EYE with a slit pupil, and a magical SWORD with a
faint blue glow beside it, the same pair in every panel, both drifting back and
forth:
Panel 1: the eye wide open, the sword upright beside it.
Panel 2: the eye and the sword both lean to the right.
Panel 3: the eye half closed and the sword lowered, as if striking.
Panel 4: both back upright, the eye wide open again.""",
    },
    "faction_war": {
        "note": "a wall of shields under a stone volley - faction wars",
        "prompt": """A WALL of four large round IRON-BOUND SHIELDS standing shoulder to shoulder,
seen from the front, and three small grey STONES flying at the wall from the left,
the same wall and the same stones in every panel. The stones are clearly visible in
the air in every panel, never absent:
Panel 1: the wall intact, all three stones far away on the left, nothing has hit yet.
Panel 2: the stones much closer and bigger, the first one striking the leftmost
shield with a bright spark.
Panel 3: two stones hit at once, bright sparks and iron chips flying, one shield
pushed back and leaning.
Panel 4: the leftmost shield torn out of the line and falling away, a clear gap in
the wall, the remaining shields still standing and leaning.""",
    },
    "story_chain": {
        "note": "a golden key opening a door - story chains",
        "prompt": """A large GOLDEN KEY hovering in front of a small arched wooden DOOR, the same
key and door in every panel:
Panel 1: the key in front of the closed door, a warm glow around the key.
Panel 2: the key turns in the lock, the glow brighter.
Panel 3: the door opens a crack, a shaft of golden light coming out.
Panel 4: the door wide open, the key still in the lock, light pouring out.""",
    },
}


def build_prompt(slug: str) -> str:
    return f"{MISSIONS[slug]['prompt']}\n\n{LAYOUT_TAIL}"


def _next_version(slug: str) -> int:
    best = 0
    for p in MISS_DIR.glob(f"{slug}_v*.png"):
        try:
            best = max(best, int(p.stem.split("_v")[-1]))
        except ValueError:
            pass
    return best + 1


def _run(slug: str, version: int, key: str, model: str, size: str) -> None:
    from gen_image_kodik import gen_once

    out = MISS_DIR / f"{slug}_v{version}.png"
    print(f"{slug}: generating {out.name} ({model}, {size})...")
    gen_once(key, model, build_prompt(slug), out, size, None, 1, None)
    n = normalize_bg(out)
    print(f"  normalize_bg: {n} px repainted to exact magenta")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="catalog of missions")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the final prompts and the price, generate nothing")
    ap.add_argument("--slug", help="mission slug to generate")
    ap.add_argument("--v", type=int, help="explicit version (default: max+1)")
    ap.add_argument("--all", action="store_true", help="generate all missions")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--size", default=SIZE)
    args = ap.parse_args()
    if args.list:
        for slug, e in MISSIONS.items():
            print(f"  {slug:<14} {e['note']}")
        return 0
    if args.dry_run:
        slugs = list(MISSIONS) if not args.slug else [args.slug]
        for slug in slugs:
            print(f"=== {slug} ({MISSIONS[slug]['note']}) ===")
            print(build_prompt(slug))
            print()
        print(f"RESULT: OK (dry-run, {len(slugs)} prompt(s), nothing generated, "
              f"would cost ${COST_PER_SHEET * len(slugs):.3f} on {args.model})")
        return 0
    from gen_image_kodik import load_key

    key = load_key()  # exits with the honest message when no key is found
    MISS_DIR.mkdir(parents=True, exist_ok=True)
    if args.all:
        for slug in MISSIONS:
            _run(slug, _next_version(slug), key, args.model, args.size)
        return 0
    if args.slug:
        if args.slug not in MISSIONS:
            print(f"ERR: unknown slug '{args.slug}' - see --list")
            return 1
        _run(args.slug, args.v if args.v else _next_version(args.slug), key,
             args.model, args.size)
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
