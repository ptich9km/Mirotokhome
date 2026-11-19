#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Пересобрать object_db.json из alm_objects.json.

ЗАЧЕМ. До 11.10 справочник объектов карты и каталог на диске разошлись:
object_db.json описывал 77 аллодовских объектов (pine1, maple2, bones,
column, bamboo*...), у которых PNG были удалены вместе с артом Аллодов, а
19 seedream-объектов (tree_oak, rock, prop_barrel...) в справочнике не
было вовсе. Итог: справочник обещал 7 кадров там, где лежал ноль файлов,
и map_object.gd грузил пустоту.

Почему из alm_objects.json, а не вручную. alm_objects.json — то, что
читает генератор карт (MapGenerator._place_objects, AlmMap) и редактор
(CustomMap). Это единственный источник правды «какие объекты есть».
Держать вторую копию тех же данных в object_db.json — значит завести
ровно ту рассинхронизацию, которую снимаем. Теперь object_db.json
СОЗДАЁТСЯ из него, и рассинхронизация невозможна по построению.

ФОРМАТ. object_db.json пишется indent=1 — так он уже был записан в
коммите 8b2d7c86, и смена отступа переформатировала бы весь файл.
Ещё object_db.json читается как Dictionary, где каждое значение —
тоже Dictionary, поэтому records[id] = {...} в Python соответствует
объекту по id. Пустые anim_time/anim_frame пишутся как []: это не
«нет анимации», а «статичный объект», и редактор различает их по
phases.

Запуск:
  python tests/gen_object_db.py            # пересобрать
  python tests/gen_object_db.py --check    # только проверить (код 1 при расхождении)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALM_OBJECTS = ROOT / "assets" / "map-objects" / "alm_objects.json"
OBJECT_DB = ROOT / "assets" / "map-objects" / "object_db.json"


def build(records: dict) -> dict:
    """Справочник объектов карты, ключ — папка объекта (ObjectDB.get_obj)."""
    out = {}
    for rec_id in sorted(records, key=lambda k: int(k)):
        r = records[rec_id]
        name = str(r["folder"])
        phases = int(r.get("phases", 1))
        frames = int(r.get("frames", 1))
        entry = {
            "desc": str(r.get("desc", name)),
            "phases": phases,
            "w": int(r.get("w", 128)),
            "h": int(r.get("h", 128)),
            "cx": int(r.get("cx", 64)),
            "cy": int(r.get("cy", 128)),
        }
        # Optional draw scale: a prop may be drawn smaller than its canvas
        # without touching the PNG (mushrooms, 0.5 since 20.11).
        if r.get("scale") is not None:
            entry["scale"] = r["scale"]
        entry.update({
            "frames": frames,
            # Анимация возможна только при нескольких фазах. Для статичного
            # объекта это [], а не отсутствие ключа: MapObject._build
            # проверяет anim_order, и отсутствие ключа читалось бы иначе.
            "anim_time": [4] * frames if phases > 1 and frames > 1 else [],
            "anim_frame": list(range(frames)) if phases > 1 and frames > 1 else [],
            "dead": None,
            "fire": None,
            "variants": [],
        })
        out[name] = entry
    return out


def dumps(db: dict) -> str:
    return json.dumps(db, ensure_ascii=False, indent=1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="не писать, только сверить и вернуть код 1 при расхождении")
    args = ap.parse_args()

    records = json.loads(ALM_OBJECTS.read_text(encoding="utf-8"))
    wanted = dumps(build(records))
    current = OBJECT_DB.read_text(encoding="utf-8") if OBJECT_DB.exists() else ""

    if args.check:
        same = current == wanted
        print("[check] object_db.json %s (%d объектов)"
              % ("совпадает" if same else "РАСХОДИТСЯ", len(build(records))))
        if not same:
            print("  текущий sha256: %s" % hashlib.sha256(current.encode()).hexdigest()[:16])
            print("  ожидаемый sha256: %s" % hashlib.sha256(wanted.encode()).hexdigest()[:16])
        return 0 if same else 1

    OBJECT_DB.write_text(wanted, encoding="utf-8")
    db = build(records)
    print("[done] object_db.json: %d объектов" % len(db))
    for name in sorted(db):
        print("  %-14s phases=%d frames=%d %dx%d"
              % (name, db[name]["phases"], db[name]["frames"], db[name]["w"], db[name]["h"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())