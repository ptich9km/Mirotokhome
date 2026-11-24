#!/usr/bin/env python3
"""Insert the teleport master unit set into assets/units/units_db.json.

Same text-insertion approach as add_head_sets_db.py: the database is
hand-formatted and json.dump would rewrite the whole file. One neutral set
`city_teleport_master/t0` serves every race - the master is a service NPC,
not a faction member (player decision 25.11).

Usage:
  py tests/add_teleport_master_db.py            # insert if missing
  py tests/add_teleport_master_db.py --replace  # rewrite (art/geometry changed)
  py tests/add_teleport_master_db.py --check    # verify entry matches the art
"""
import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "assets" / "units" / "units_db.json"
FOLDER = "city_teleport_master/t0"
FRAMES_DIR = REPO / "assets" / "units" / "city_teleport_master" / "t0"

TEMPLATE = ''' "{key}": {{
  "desc": "Мастер телепортации, нейтральный служитель",
  "name_ru": "Мастер телепортации",
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


def sel_box() -> tuple[int, int, int, int]:
    """Selection box: the opaque content of the down-facing frame."""
    from PIL import Image
    import numpy as np
    path = FRAMES_DIR / "sprites-001.png"
    a = np.asarray(Image.open(path).convert("RGBA"), dtype=np.int32)
    ys, xs = np.nonzero(a[..., 3] > 40)
    if len(xs) == 0:
        raise SystemExit("empty frame: %s" % path)
    return int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1)


def entry() -> str:
    sx, sy, sw, sh = sel_box()
    return TEMPLATE.format(key=FOLDER, folder=FOLDER,
                           sel_x=sx, sel_y=sy, sel_w=sw, sel_h=sh)


def drop_entry(raw: str, key: str) -> str:
    """Remove one "key": {...} block (brace counting; no braces in strings)."""
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
                    end += 2 if raw[end] == "\r" else 1
                return raw[:start] + raw[end:]
        j += 1
    return raw


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--replace", action="store_true")
    args = ap.parse_args()

    n = len(sorted(FRAMES_DIR.glob("sprites-*.png")))
    if n != 8:
        print("FAIL: %s has %d frames, expected 8" % (FOLDER, n))
        return 1

    raw = DB.read_text(encoding="utf-8")
    if args.check:
        db = json.loads(raw)
        if FOLDER not in db:
            print("MISSING: %s" % FOLDER)
            return 1
        want = {
            "frames": 8, "dirs": 8, "idle_phases": 0, "move": 1,
            "attack": 0, "dying": 0, "decay": 0, "blocks": 1,
            "w": 52, "h": 64, "cx": 26, "cy": 62,
            "folder": FOLDER, "name_ru": "Мастер телепортации",
        }
        bad = 0
        got = db[FOLDER]
        for k, v in want.items():
            if got.get(k) != v:
                print("BAD %s.%s = %r, expected %r" % (FOLDER, k, got.get(k), v))
                bad += 1
        if list(got.get("sel_box", [])) != list(sel_box()):
            print("BAD %s.sel_box = %r, expected %r"
                  % (FOLDER, got.get("sel_box"), sel_box()))
            bad += 1
        print("RESULT: %s teleport master db entry" % ("OK" if bad == 0 else "FAIL"))
        return 0 if bad == 0 else 1

    if args.replace:
        raw = drop_entry(raw, FOLDER)
    elif '"%s"' % FOLDER in raw:
        print("nothing to insert: %s is already in the database" % FOLDER)
        return 0

    i = raw.rindex("}")
    head = raw[:i].rstrip()
    if not head.endswith(","):
        head += ","
    DB.write_text(head + "\n" + entry() + "\n}\n", encoding="utf-8", newline="")
    db = json.loads(DB.read_text(encoding="utf-8"))
    print("inserted: %s (total sets: %d)" % (FOLDER, len(db)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
