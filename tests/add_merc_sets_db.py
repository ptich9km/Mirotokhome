#!/usr/bin/env python3
"""Insert the mercenary unit sets into units_db.json.

The sets are produced by tests/gen_hero_strip.py (four 4-panel strips) and cut by
tests/extract_hero_nb.py --tag <tag> --dest merc, which writes
assets/units/merc/<race>_<class>/t<tier>/sprites-001..012.png: the same 12-frame
contract the hero sets use (idle1 + move4 + attack3 + dying4), one three-quarter
view plus a horizontal mirror.

Why own sets instead of reusing the hero art: the inn used to hire
`ork_mage_a52/t0..t3`, four static orc mages, in every city of every race. The
hero sets are the player's own sixteen looks, so pointing the inn at them would
spawn copies of the player. These sets are drawn with the same prompts (same
race, same class, same gear language) but are separate art.

Tiers. A tier in this project is a GEAR LADDER, not a palette swap: the city sets
t0..t3 are leather -> breastplate -> breastplate+helmet -> full plate. Recolouring
was measured and rejected (on warriors the skin and leather dominate the palette,
so a "tier" recolour would repaint the face). So a mercenary set has two grades:
t0 as drawn, t1 the same character with added gear (helmet + shin plates for a
warrior, gold trim for a mage, see gen_hero_strip.TIER_ELITE).

Not every set got a t1: the t1 art of `human_warrior` loses its helmet in the idle
and attack strips, and the t1 walk strip of `druid_mage` was drawn across the
panel edge. Both need a reroll, which needs API balance, so Tier 1 is absent for
those two sets and the inn pool simply has one grade less.

`desc` is what the inn prints as the candidate name (UnitDB.display_name), so it
holds the human-readable name and not the pipeline note.

Usage:
  python tests/add_merc_sets_db.py            # insert missing entries, drop stale
  python tests/add_merc_sets_db.py --check    # verify entries against the art
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "assets" / "units" / "units_db.json"
UNITS = REPO / "assets" / "units" / "merc"

## (folder under assets/units/merc, tiers with art on disk)
SETS = [
    ("human_warrior", (0,)),
    ("human_mage", (0, 1)),
    ("orc_warrior", (0, 1)),
    ("orc_mage", (0, 1)),
    ("druid_warrior", (0, 1)),
    ("druid_mage", (0,)),
    ("undead_warrior", (0, 1)),
    ("undead_mage", (0, 1)),
    # Archer (17.11): ranged mercenary, tier 0 only so far.
    ("human_archer", (0,)),
    ("orc_archer", (0,)),
    ("druid_archer", (0,)),
    ("undead_archer", (0,)),
]

RACES = {
    "human": ("человек", "human"),
    "orc": ("орк", "orc"),
    "druid": ("друид", "druid"),
    "undead": ("нежить", "undead"),
}
CLASSES = {"warrior": ("воин", "warrior"), "mage": ("маг", "mage"),
           "archer": ("лучник", "archer")}

WANT = {
    "frames": 12, "dirs": 1, "idle_phases": 1, "move": 4, "attack": 3,
    "dying": 4, "decay": 0, "blocks": 4, "w": 64, "h": 64, "cx": 32, "cy": 62,
}

FIELDS = """  "desc": "%s",
  "desc_en": "%s",
  "folder": "%s",
  "frames": 12,
  "prefix": "sprites",
  "dirs": 1,
  "idle_phases": 1,
  "move": 4,
  "move_begin": 0,
  "attack": 3,
  "dying": 4,
  "decay": 0,
  "cast": 0,
  "idle": 0,
  "move_f": [],
  "move_t": [],
  "attack_f": [],
  "attack_t": [],
  "die_f": [],
  "dying_t": [],
  "w": 64,
  "h": 64,
  "cx": 32,
  "cy": 62,
  "tile": null,
  "projectile": -1,
  "palette": 0,
  "blocks": 4,
  "resist": {
   "fire": 10,
   "water": 10,
   "air": 10,
   "earth": 10,
   "astral": 10
  }"""


def names(folder: str, tier: int) -> tuple[str, str]:
    race_en, cls_en = folder.split("_")
    race_ru, race_en = RACES[race_en]
    cls_ru, cls_en = CLASSES[cls_en]
    if race_en == "undead":
        # "воин нежити", not "нежить-воин": the race is a people, not an adjective.
        if tier == 0:
            return (f"Наёмник: {cls_ru} нежити", f"Mercenary: {race_en} {cls_en}")
        return (f"Наёмник-ветеран: {cls_ru} нежити",
                f"Veteran mercenary: {race_en} {cls_en}")
    if tier == 0:
        return (f"Наёмник: {race_ru}-{cls_ru}", f"Mercenary: {race_en} {cls_en}")
    return (f"Наёмник-ветеран: {race_ru}-{cls_ru}",
            f"Veteran mercenary: {race_en} {cls_en}")


def key_of(folder: str, tier: int) -> str:
    return f"merc/{folder}/t{tier}"


def block(folder: str, tier: int) -> str:
    ru, en = names(folder, tier)
    key = key_of(folder, tier)
    return ' "%s": {\n%s\n }' % (key, FIELDS % (ru, en, key))


def drop_entry(raw: str, key: str) -> str:
    """Remove one entry: brace counting is enough, no braces inside strings."""
    head = '"%s": {' % key
    i = raw.find(head)
    if i < 0:
        return raw
    start = i - 1
    depth = 0
    j = raw.index("{", i)
    while j < len(raw):
        if raw[j] == "{":
            depth += 1
        elif raw[j] == "}":
            depth -= 1
            if depth == 0:
                end = j + 1
                if raw.startswith(",", end):
                    end += 1
                while end < len(raw) and raw[end] in " \t":
                    end += 1
                if end < len(raw) and raw[end] in "\r\n":
                    end += 1
                return raw[:start] + raw[end:]
        j += 1
    return raw


def frames_on_disk(folder: str, tier: int) -> int:
    return len(sorted((UNITS / folder / f"t{tier}").glob("sprites-*.png")))


def wanted() -> list[tuple[str, int]]:
    return [(folder, tier) for folder, tiers in SETS for tier in tiers]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    raw = DB.read_text(encoding="utf-8")
    db = json.loads(raw)

    if args.check:
        problems = 0
        for folder, tier in wanted():
            key = key_of(folder, tier)
            data = db.get(key)
            if data is None:
                print(f"MISSING {key}")
                problems += 1
                continue
            count = frames_on_disk(folder, tier)
            if count != 12:
                print(f"ART     {key}: {count} frames on disk, expected 12")
                problems += 1
            for field, value in WANT.items():
                if data.get(field) != value:
                    print(f"FIELDS  {key}: {field}={data.get(field)!r} expected {value!r}")
                    problems += 1
            if data.get("folder") != key:
                print(f"FOLDER  {key}: {data.get('folder')!r}")
                problems += 1
            ru, en = names(folder, tier)
            if data.get("desc") != ru or data.get("desc_en") != en:
                print(f"NAME    {key}: {data.get('desc')!r} / {data.get('desc_en')!r}")
                problems += 1
        stale = [k for k in db if k.startswith("merc/") and k not in
                 {key_of(f, t) for f, t in wanted()}]
        for key in stale:
            print(f"STALE   {key} (art layout changed, entry must be dropped)")
            problems += 1
        print("RESULT: OK" if problems == 0 else f"RESULT: {problems} problem(s)")
        return 0 if problems == 0 else 1

    # Drop every mercenary entry, then insert the current set: the tier layout
    # changed from merc/<set> to merc/<set>/t0, and a stale key would keep an
    # entry that points at a folder which no longer holds sprites.
    for key in [k for k in db if k.startswith("merc/")]:
        raw = drop_entry(raw, key)

    rows = wanted()
    for folder, tier in rows:
        if frames_on_disk(folder, tier) != 12:
            print(f"refused: {folder} t{tier} has {frames_on_disk(folder, tier)} "
                  f"frames on disk, expected 12")
            return 1

    tail = raw.rstrip()
    if not tail.endswith("}"):
        print("refused: units_db.json does not end with a closing brace")
        return 1
    body = tail[:-1].rstrip()
    if body.endswith(","):
        # Dropping the last entries leaves the comma of the entry before them.
        body = body[:-1].rstrip()
    if not body.endswith("}"):
        print("refused: unexpected database layout")
        return 1
    raw = body + ",\n" + ",\n".join(block(f, t) for f, t in rows) + "\n}\n"
    DB.write_text(raw, encoding="utf-8", newline="")

    check = json.loads(DB.read_text(encoding="utf-8"))
    for folder, tier in rows:
        if key_of(folder, tier) not in check:
            print(f"insert did not survive the re-read: {key_of(folder, tier)}")
            return 1
    print(f"wrote {len(rows)} mercenary set(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
