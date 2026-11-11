#!/usr/bin/env python3
"""Insert the four city-head unit sets into assets/units/units_db.json.

The file is hand-formatted (one-space keys, two-space fields), so json.dump would
rewrite the whole base and the diff would drown in reindent noise. The entries are
inserted as text right before the closing brace, the same way add_sw_seed_db.py
does it.

Usage:
  python tests/add_head_sets_db.py            # insert missing entries
  python tests/add_head_sets_db.py --replace  # rewrite the four entries (art/geometry changed)
  python tests/add_head_sets_db.py --check    # verify entries match the art on disk
"""
import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "assets" / "units" / "units_db.json"
UNITS = REPO / "assets" / "units"

RACES = ("human", "ork", "necro", "druid")
DESC = {
    "human": "Горожанин-глава, человек",
    "ork": "Горожанин-глава, орк",
    "necro": "Горожанин-глава, нежить",
    "druid": "Горожанин-глава, друид",
}
NAME_RU = {
    "human": "Глава города",
    "ork": "Глава орков",
    "necro": "Глава нежити",
    "druid": "Глава друидов",
}

TEMPLATE = ''' "{key}": {{
  "desc": "{desc}",
  "name_ru": "{name_ru}",
  "folder": "{folder}",
  "prefix": "sprites",
  "frames": 8,
  "dirs": 8,
  "move": 1,
  "move_begin": 0,
  "attack": 0,
  "dying": 0,
  "decay": 0,
  "cast": 0,
  "idle": 0,
  "idle_phases": 0,
  "move_f": [
   0
  ],
  "move_t": [
   2
  ],
  "attack_f": [],
  "attack_t": [],
  "die_f": [],
  "dying_t": [],
  "w": 52,
  "h": 64,
  "cx": 26,
  "cy": 62,
  "tile": null,
  "projectile": -1,
  "palette": 0,
  "ids": [],
  "picture": null,
  "blocks": 1,
  "expected_frames": 8,
  "sel_box": [
   {sel_x},
   {sel_y},
   {sel_w},
   {sel_h}
  ],
  "attack_delay": 4,
  "info_picture": null,
  "sound": [],
  "resist": {{
   "fire": 0,
   "water": 0,
   "air": 0,
   "earth": 0,
   "astral": 0
  }},
  "tile_size": 1,
  "z": 0,
  "flip": 0,
  "bone": 0,
  "shoot_delay": 8,
  "shoot_offset": []
 }}'''


def sel_box(race: str) -> tuple[int, int, int, int]:
    """Selection box of the set: the opaque content of the down-facing frame."""
    from PIL import Image
    import numpy as np
    path = UNITS / ("city_%s_head" % race) / "t0" / "sprites-001.png"
    a = np.asarray(Image.open(path).convert("RGBA"), dtype=np.int32)
    ys, xs = np.nonzero(a[..., 3] > 40)
    if len(xs) == 0:
        raise SystemExit("empty frame: %s" % path)
    return int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1)


def entry(race: str) -> str:
    folder = "city_%s_head/t0" % race
    sx, sy, sw, sh = sel_box(race)
    return TEMPLATE.format(
        key=folder, desc=DESC[race], name_ru=NAME_RU[race], folder=folder,
        sel_x=sx, sel_y=sy, sel_w=sw, sel_h=sh)


def frames_of(race: str) -> int:
    folder = UNITS / ("city_%s_head" % race) / "t0"
    return len(sorted(p for p in folder.glob("sprites-*.png")))


def drop_entry(raw: str, key: str) -> str:
    """Remove one "key": {...} block from the hand-formatted database text.

    Brace counting is enough here: the entries contain no braces inside strings.
    """
    head = '"%s": {' % key
    i = raw.find(head)
    if i < 0:
        return raw
    start = i - 1                     # the leading space of the key line
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
                if end < len(raw) and raw[end] == "\n":
                    end += 1
                elif end < len(raw) and raw[end] in "\r\n":
                    end += 1
                return raw[:start] + raw[end:]
        j += 1
    return raw


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--replace", action="store_true",
                    help="rewrite the four entries (the art changed)")
    args = ap.parse_args()

    for race in RACES:
        n = frames_of(race)
        if n != 8:
            print("FAIL: %s has %d frames, expected 8" % (race, n))
            return 1

    raw = DB.read_text(encoding="utf-8")
    if args.replace:
        for race in RACES:
            raw = drop_entry(raw, "city_%s_head/t0" % race)
        missing = list(RACES)
    else:
        missing = [r for r in RACES if '"city_%s_head/t0"' % r not in raw]

    if args.check:
        db = json.loads(raw)
        bad = 0
        for race in RACES:
            key = "city_%s_head/t0" % race
            if key not in db:
                print("MISSING: %s" % key)
                bad += 1
                continue
            want = {
                "frames": 8, "dirs": 8, "idle_phases": 0, "move": 1,
                "attack": 0, "dying": 0, "decay": 0, "blocks": 1,
                "w": 52, "h": 64, "cx": 26, "cy": 62,
                "folder": key, "name_ru": NAME_RU[race],
            }
            got = db[key]
            for k, v in want.items():
                if got.get(k) != v:
                    print("BAD %s.%s = %r, expected %r" % (key, k, got.get(k), v))
                    bad += 1
            if list(db[key].get("sel_box", [])) != list(sel_box(race)):
                print("BAD %s.sel_box = %r, expected %r"
                      % (key, db[key].get("sel_box"), sel_box(race)))
                bad += 1
        print("RESULT: %s head db entries" % ("OK" if bad == 0 else "FAIL"))
        return 0 if bad == 0 else 1

    if not missing:
        print("nothing to insert: all four head sets are in the database")
        return 0

    i = raw.rindex("}")
    head = raw[:i].rstrip()
    if not head.endswith(","):
        head += ","
    blocks = ",\n".join(entry(r) for r in RACES if r in missing)
    out = head + "\n" + blocks + "\n}\n"
    DB.write_text(out, encoding="utf-8", newline="")

    db = json.loads(DB.read_text(encoding="utf-8"))
    print("inserted: %s (total sets: %d)" % (", ".join(missing), len(db)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
