#!/usr/bin/env python3
"""Insert the traveler unit set (the rescued NPC) into units_db.json.

The set is produced by tests/gen_hero_strip.py --class traveler (four 4-panel
strips) and cut by tests/extract_hero_nb.py --tag tv1 --dest npc, which writes
assets/units/npc/traveler_m/sprites-001..012.png (idle1 + move4 + attack3 +
dying4) -- the same 12-frame contract the hero sets use, one 3/4 view plus a
horizontal mirror for the left side.

The attack block exists only because the contract is fixed at 12 frames; a
rescued NPC never attacks.

Usage:
  python tests/add_traveler_db.py            # insert the entry if missing
  python tests/add_traveler_db.py --replace  # rewrite it (art changed)
  python tests/add_traveler_db.py --check    # verify against the art on disk
"""
import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "assets" / "units" / "units_db.json"
SET_DIR = REPO / "assets" / "units" / "npc" / "traveler_m"
KEY = "npc/traveler_m"

DESC = ("Traveler: peaceful NPC of the rescue event, 4-panel strips (Gemini 3.1 "
        "Flash), three-quarter east view + mirror, idle1+move4+attack3+dying4")
NAME_RU = "Путник"

ENTRY = ''' "npc/traveler_m": {
  "desc": "%s",
  "name_ru": "%s",
  "folder": "npc/traveler_m",
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
  }
 }''' % (DESC, NAME_RU)

WANT = {
    "frames": 12, "dirs": 1, "idle_phases": 1, "move": 4, "attack": 3,
    "dying": 4, "decay": 0, "blocks": 4, "w": 64, "h": 64, "cx": 32, "cy": 62,
    "folder": "npc/traveler_m",
}


def frames_on_disk() -> int:
    return len(sorted(SET_DIR.glob("sprites-*.png")))


def drop_entry(raw: str) -> str:
    """Remove the entry block: brace counting is enough, no braces inside strings."""
    head = '"%s": {' % KEY
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--replace", action="store_true")
    args = ap.parse_args()

    n = frames_on_disk()
    if n != 12:
        print("FAIL: %s has %d frames, expected 12" % (SET_DIR, n))
        return 1

    raw = DB.read_text(encoding="utf-8")

    if args.check:
        db = json.loads(raw)
        if KEY not in db:
            print("MISSING: %s" % KEY)
            return 1
        bad = 0
        for k, v in WANT.items():
            if db[KEY].get(k) != v:
                print("BAD %s.%s = %r, expected %r" % (KEY, k, db[KEY].get(k), v))
                bad += 1
        print("RESULT: %s traveler db entry" % ("OK" if bad == 0 else "FAIL"))
        return 0 if bad == 0 else 1

    if args.replace:
        raw = drop_entry(raw)
    elif '"%s"' % KEY in raw:
        print("nothing to insert: %s is already in the database" % KEY)
        return 0

    i = raw.rindex("}")
    head = raw[:i].rstrip()
    if not head.endswith(","):
        head += ","
    DB.write_text(head + "\n" + ENTRY + "\n}\n", encoding="utf-8", newline="")
    db = json.loads(DB.read_text(encoding="utf-8"))
    print("inserted %s (total sets: %d)" % (KEY, len(db)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
