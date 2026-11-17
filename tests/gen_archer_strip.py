#!/usr/bin/env python3
"""Archer mercenary strips (17.11): stand / walk / attack(bow shot) / die.

Why a separate generator instead of `--class archer` in gen_hero_strip.py: the
archer contract is not "a warrior holding something", it is a WEAPON THAT MUST
SURVIVE THE WHOLE SHEET. The prompt blocks here are the fix for that, measured on
the first attempts (see docs/journal/2026-11.md, 17.11):

  * gemini-3.1-flash-lite-image drew the bow only while it was raised: in the
    release panel the hand was empty (component width 210 px against 255-292 px
    in the other three). The WEAPON LOCK paragraph fixed it (all four panels
    261-292 px wide, bow present).
  * figures came out ~70 percent of the image height, so the SIZE LAW paragraph
    gives the model exact pixel arithmetic;
  * the quiver slid from the back to the hip between panels — GEAR LOCK pins it.

Model: google/gemini-3.1-flash-lite-image ($0.034 per strip, 4-7 s) is the
cheapest one that keeps the bow; seedream-5-0-flash ($0.018) is cheaper and also
keeps it, with a painterly look closer to the older mercenary sets. Both take
`aspect_ratio` + `resolution` instead of `size`, so the call passes them in
`extra`.

Usage:
  python tests/gen_archer_strip.py stand --race human --out import/review/archer/x.png
  python tests/gen_archer_strip.py attack --race orc --model bytedance-seed/seedream-5-0-flash
  python tests/gen_archer_strip.py walk --race druid --dry-run     # print the prompt only

Then cut with the ordinary toolchain:
  copy the four strips to import/Player as hero_<anim>_<tag>.png and run
  python tests/extract_hero_nb.py --tag mha --dest merc        (tags: mha/m oa/mda/mua)
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

import gen_hero_strip as gh  # noqa: E402

MODEL = "google/gemini-3.1-flash-lite-image"
OUT_DIR = REPO / "import" / "review" / "archer"

## Per-model request shape: the Gemini family takes aspect_ratio/resolution.
EXTRA = {"aspect_ratio": "3:2", "resolution": "1K"}

GEAR_LOCK = """GEAR LOCK - the equipment is identical in every panel:
- the quiver stays on his BACK with the fletching above the RIGHT shoulder, it
  never slides down to the hip and never appears in front of his chest;
- the wooden bow stays in his LEFT hand the whole time, it never switches hands,
  never disappears, never grows or shrinks;
- there is no plate armour, no metal breastplate, no shoulder pads, no gauntlets."""

WEAPON_LOCK = """WEAPON LOCK - this is the hardest rule of the whole sheet:
- there is exactly ONE bow in a panel, and the LEFT hand grips it by its middle;
- the bow is VISIBLE IN ALL FOUR PANELS, in the SAME left hand, drawn the same
  size and the same shape; it never hangs on the belt, never hides behind the
  body, never turns into a second bow, never disappears;
- the bowstring is ONE straight line from the upper tip to the lower tip;
- the arrow either sits on the string or is already gone: it is never stuck in
  his chest, never floating in the air, never cut by the frame edge;
- in the release panel the bow is STILL in his left hand with the string straight."""

SIZE_LAW = """SIZE CHECK - do the arithmetic BEFORE drawing, the numbers are exact:
the image is 1536 x 1024 pixels. Each of the four figures must be at most 270
pixels wide and at most 450 pixels tall, so that all four stand in one row with
wide magenta gaps between them. Keep the top 30 percent and the bottom 20 percent
of the image COMPLETELY EMPTY: no figure may touch those bands. A figure taller
than 450 pixels is a REJECTED frame. Draw the figures SMALL."""

CHARACTERS = {
    "human": """ONE single character repeated in every panel: a sturdy adult human
ARCHER, light skin, short brown hair, short trimmed brown beard, no cape, no
helmet, no hood. He wears a plain brown leather jerkin laced at the front with no
armour plates, a broad brown leather belt, dark green wool trousers and brown
leather boots. A QUIVER of six arrows with grey fletching is strapped on his BACK,
the fletching visible above his RIGHT shoulder. A plain wooden short bow is
gripped in his LEFT hand.""",
    "orc": """ONE single character repeated in every panel: a broad-shouldered,
sturdy adult ORC ARCHER, tall and heavily built, rough olive-green skin, a heavy
brow ridge, deep set glowing amber eyes, a broad flat nose, large curved white
tusks coming up from the lower jaw, thick black hair tied into a short rough tail,
a scar across one cheek. He wears a plain brown leather jerkin laced at the front,
a wide brown leather belt, dark brown trousers and heavy brown leather boots. A
QUIVER of six arrows with grey fletching is strapped on his BACK, the fletching
visible above his RIGHT shoulder. A plain wooden short bow is gripped in his LEFT
hand.""",
    "druid": """ONE single character repeated in every panel: a broad-shouldered,
sturdy adult human DRUID ARCHER of the Circle of Druids, tanned weathered skin,
long thick grey-brown hair and a full grey-brown beard, no hood, no cape, no
helmet, no antlers, no leaves or twigs in the hair. He wears a bark-brown
hardened leather chest piece, a thick woven rope belt, plain brown leather
bracers, dark green trousers and rough brown leather boots. A QUIVER of six arrows
with grey fletching is strapped on his BACK, the fletching visible above his RIGHT
shoulder. A plain wooden short bow is gripped in his LEFT hand. NO straps, NO
hanging vines or ribbons, NO small twigs, beads or tiny details.""",
    "undead": """ONE single character repeated in every panel: a tall,
powerfully built UNDEAD SKELETON ARCHER of the Harvesters faction, thick heavy
bones, bare bone-white skull with deep dark eye sockets and a faint green glow
deep in the eyes, exposed bone-white ribcage, spine, arms and legs, no flesh, no
hair, no rotting tissue. THE ARMS AND LEGS ARE BARE BONES: thin straight white
twin bones with round joints, like a Halloween skeleton, NOT muscular, NOT fleshy.
He wears a battered dark brown leather jerkin laced over the ribcage and a wide
brown leather belt. A QUIVER of six arrows with grey fletching is strapped on his
BACK, the fletching visible above his RIGHT shoulder. A plain wooden short bow is
gripped in his LEFT hand.""",
}

STAND = """AN IDLE STANCE, 4 panels left to right in one row.
Panel 1: standing still, feet about hip width apart, the bow held low in his left
hand with the string straight, the right arm hanging relaxed at his side.
Panels 2, 3 and 4: the exact same standing pose, only a tiny breathing difference
in the rise of his chest. He does not move his feet and does not move the bow."""

WALK = """A WALKING CYCLE, 4 panels left to right in one row, calm even walking pace.
The bow is carried low in his left hand in all four panels, the left arm stays
mostly still and close to the body; only the RIGHT arm swings freely.
Panel 1 CONTACT: the front heel just touched the ground, the back leg stretched
behind, legs at their widest apart, body upright, spine straight.
Panel 2 DOWN: his weight rolls onto the front leg, the back leg still stretched
behind pushing off, the knees nearly straight, the spine upright; he does NOT
crouch, bend forward, squat, kneel or run.
Panel 3 PASSING: the back foot swings forward and steps up beside the front foot,
legs TOGETHER, feet almost touching, body at its tallest. This panel is the
NARROWEST of the four.
Panel 4 PUSH OFF: he rises onto the toes of the back foot, the back leg trailing at
an angle, the front leg starting to reach forward.
BANNED in panels 3 and 4: a wide straddle, a deep lunge, a horse stance, a squat."""

SHOOT = """A BOW SHOT, 4 panels left to right in one row.
Panel 1: standing, the bow held low in the left hand at waist height, string
straight, an arrow resting on the string.
Panel 2: the bow raised in front of him to shoulder height, the string drawn a
third of the way, the arrow pointing to the LEFT edge of the image.
Panel 3: the string drawn fully back to his cheek, the right elbow high, the
arrow still on the string, pointing LEFT.
Panel 4: release. The string has sprung back straight, the right hand is open
next to his cheek, the arrow has left - and the bow is still gripped in his left
hand exactly as in the other three panels.
The bow does NOT change hands, does NOT vanish, and no second bow appears."""

DIE = """A FALL TO THE GROUND, 4 panels left to right in one row.
Panel 1: standing upright, the right arm flung wide open to the side, the bow
still in his left hand.
Panel 2: his knees buckle, he drops downwards, the torso already tilted, the bow
falling out of his hand towards the ground.
Panel 3: he has fallen over onto the ground, the body turned down onto its side,
torso nearly horizontal, the arms folded in tight against the chest and NOT
stretched out towards the neighbouring panel.
Panel 4: LYING ON THE GROUND ON HIS BACK, face and chest pointing up, knees
slightly bent, arms relaxed on the ground, the whole fallen figure fits inside its
own quarter of the image width. The bow lies on the ground next to him, inside the
same quarter. Do NOT draw the fallen body stretched out across a wide area.
He NEVER lies face down.
BANNED in panels 3 and 4: sitting upright, squatting, kneeling upright, resting on
the hands behind the back, legs dangling down, a compact round shape."""

POSES = {"stand": STAND, "walk": WALK, "attack": SHOOT, "die": DIE}

## Tags for the cutter (extract_hero_nb.SETS), so the strip names are obvious.
TAGS = {"human": "mha", "orc": "moa", "druid": "mda", "undead": "mua"}


def build_prompt(race: str, anim: str) -> str:
    proportions = gh.PROPORTIONS_U if race == "undead" else gh.PROPORTIONS
    return "\n\n".join([
        CHARACTERS[race], proportions, gh.VIEW, gh.VIEW_LOCK,
        GEAR_LOCK, WEAPON_LOCK, POSES[anim], gh.LAYOUT4, SIZE_LAW,
    ])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("anim", choices=sorted(POSES))
    ap.add_argument("--race", choices=sorted(CHARACTERS), default="human")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--seed", type=int, default=20261117)
    ap.add_argument("--out", default="")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the prompt and the target path, call nothing")
    args = ap.parse_args()

    prompt = build_prompt(args.race, args.anim)
    out = Path(args.out) if args.out else OUT_DIR / \
        f"archer_{args.race}_{args.anim}.png"
    if args.dry_run:
        print(prompt)
        print("\n--- target:", out, "model:", args.model)
        return 0
    from gen_image_kodik import gen_once, load_key
    gen_once(load_key(), args.model, prompt, out, None, args.seed, 1, EXTRA)
    from gen_hero_strip import normalize_bg
    normalize_bg(out)
    print(f"strip: {out}\ncut it with: python tests/extract_hero_nb.py "
          f"--tag {TAGS[args.race]} --dest merc")
    return 0


if __name__ == "__main__":
    sys.exit(main())
