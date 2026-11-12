#!/usr/bin/env python3
"""Add localization keys to assets/locale/ui.json without reformatting the file.

The table is hand-maintained and mixes two layouts: older entries are spread over
three lines, newer ones sit on one line. `json.dump` would rewrite the whole file
and produce a diff of 300 lines for a three-key change, so keys are inserted
textually, right before the closing brace, one line per key.

Input is a JSON file of new entries:

    {
      "ui.hud.cast.no_enemy": {
        "ru": "Нет врага под курсором — укажите противника.",
        "en": "No enemy under the cursor — pick a target."
      }
    }

Usage:
  python tests/add_loc_keys.py keys.json           # insert missing keys
  python tests/add_loc_keys.py keys.json --check   # verify they are present
"""

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TABLE = REPO / "assets" / "locale" / "ui.json"
LOCALES = ("ru", "en")


def load_table() -> dict:
    return json.loads(TABLE.read_text(encoding="utf-8"))


def validate(new: dict) -> list:
    problems = []
    for key, value in new.items():
        if not isinstance(value, dict):
            problems.append(f"{key}: entry is not an object")
            continue
        for code in LOCALES:
            text = value.get(code, "")
            if not isinstance(text, str) or text.strip() == "":
                problems.append(f"{key}: empty or missing '{code}'")
    return problems


def insert(new: dict) -> tuple:
    table = load_table()
    missing = {k: v for k, v in new.items() if k not in table}
    if not missing:
        return 0, len(new)

    text = TABLE.read_text(encoding="utf-8")
    cut = text.rstrip().rfind("}")
    if cut < 0:
        raise SystemExit("ui.json has no closing brace")
    head = text[:cut].rstrip()
    if not head.endswith(","):
        head += ","
    lines = [f'  "{key}": ' + json.dumps(value, ensure_ascii=False).replace('", "', '", "')
             for key, value in missing.items()]
    rendered = ",\n".join(lines)
    TABLE.write_text(head + "\n" + rendered + "\n}\n", encoding="utf-8")

    # The insert is textual, so the result must still parse and contain the keys.
    reloaded = load_table()
    for key in missing:
        if key not in reloaded:
            raise SystemExit(f"{key} did not survive the insert")
    return len(missing), len(new) - len(missing)


def check(new: dict) -> int:
    table = load_table()
    bad = []
    for key, value in new.items():
        entry = table.get(key)
        if not isinstance(entry, dict):
            bad.append(f"MISSING {key}")
            continue
        for code in LOCALES:
            if not str(entry.get(code, "")).strip():
                bad.append(f"EMPTY {key}.{code}")
    for line in bad:
        print(line)
    print(f"RESULT: {'OK' if not bad else 'FAIL'} ({len(new)} keys)")
    return 0 if not bad else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("keys", help="JSON file with new entries")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    new = json.loads(Path(args.keys).read_text(encoding="utf-8"))
    problems = validate(new)
    if problems:
        for p in problems:
            print("INVALID", p)
        return 1
    if args.check:
        return check(new)

    added, skipped = insert(new)
    print(f"added {added}, already present {skipped}, total keys {len(load_table())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
